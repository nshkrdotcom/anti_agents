defmodule Mix.Tasks.AntiAgents.Benchmark do
  @moduledoc """
  Run a matched-budget AntiAgents benchmark across a fields JSON file.
  """

  use Mix.Task

  alias AntiAgents.Embedding.GeminiClient

  @shortdoc "Runs a matched-budget AntiAgents benchmark"

  @switches [
    fields: :string,
    profile: :string,
    out: :string,
    dry_run: :boolean,
    diagnostic: :boolean,
    expensive: :boolean,
    branching: :integer,
    repetitions: :integer,
    concurrency: :integer,
    rounds: :integer,
    distance: :string,
    baseline: :string,
    model: :string,
    reasoning: :string,
    temperature: :float,
    frontier_temperature_sweep: :string,
    embedding_model: :string,
    embedding_task_type: :string,
    embedding_dimensions: :integer,
    embedding_auth: :string,
    bootstrap_resamples: :integer,
    baseline_retry_budget: :integer,
    heartbeat_ms: :integer,
    preview_chars: :integer,
    timeout_ms: :integer,
    verbose: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        opts
        |> normalize_opts()
        |> run_benchmark()

      {_opts, _args, invalid} ->
        Mix.raise("Invalid options: #{inspect(invalid)}\n\n#{usage()}")
    end
  end

  defp usage do
    """
    Usage:
      mix anti_agents.benchmark --fields priv/benchmarks/fields_v1.json [options]

    Options:
      --dry-run                 print benchmark plan without provider calls
      --profile PATH            load evidence profile defaults
      --diagnostic              allow low-budget diagnostic runs; not evidence
      --branching N             frontier bursts per field/repetition, default 8
      --repetitions N           repetitions per field, default 3
      --baseline LIST           plain,paraphrase,seed_injection,temp:0.8|1.0|1.2
      --frontier-temperature-sweep LIST
                                round-robin frontier temperatures, e.g. 1.0|1.1|1.2
      --embedding-model MODEL   Gemini embedding model, default gemini-embedding-001
      --embedding-task-type T    Gemini task type, default clustering
      --embedding-dimensions N   Gemini output dimensionality, default 768
      --embedding-auth AUTH      optional gemini_ex auth strategy: gemini or vertex_ai
      --bootstrap-resamples N   default 2000
      --heartbeat-ms N          verbose heartbeat interval, default 5000
      --preview-chars N         chars of prompt/output preview, default 180
      --out PATH                write JSON report to PATH
      --expensive               allow large planned call counts
    """
  end

  defp normalize_opts(opts) do
    fields = Keyword.get(opts, :fields) || Mix.raise("--fields is required")
    profile_path = Keyword.get(opts, :profile)
    profile = load_profile(profile_path)
    distance = option(opts, profile, :distance, "jaccard")

    %{
      fields_path: fields,
      profile_path: profile_path,
      profile_id: Map.get(profile, "id"),
      profile_overrides: profile_overrides(opts, profile),
      out: Keyword.get(opts, :out),
      dry_run: Keyword.get(opts, :dry_run, false),
      diagnostic: Keyword.get(opts, :diagnostic, false),
      expensive: Keyword.get(opts, :expensive, false),
      branching: option(opts, profile, :branching, 8),
      repetitions: option(opts, profile, :repetitions, 3),
      concurrency: Keyword.get(opts, :concurrency, System.schedulers_online()),
      rounds: option(opts, profile, :rounds, 1),
      distance: distance,
      baseline: parse_baseline(option(opts, profile, :baseline, nil)),
      model: option(opts, profile, :model, AntiAgents.CodexConfig.default_model()),
      reasoning_effort:
        opts
        |> Keyword.get(
          :reasoning,
          Map.get(profile, "reasoning_effort", AntiAgents.CodexConfig.default_reasoning_effort())
        )
        |> AntiAgents.CodexConfig.normalize_reasoning_effort(),
      temperature: option(opts, profile, :temperature, 1.05),
      frontier_temperature_sweep:
        parse_temperature_sweep(option(opts, profile, :frontier_temperature_sweep, nil)),
      embedding_model:
        option(
          opts,
          profile,
          :embedding_model,
          GeminiClient.default_model()
        ),
      embedding_task_type:
        opts
        |> option(
          profile,
          :embedding_task_type,
          GeminiClient.default_task_type()
        )
        |> GeminiClient.normalize_task_type(),
      embedding_dimensions:
        option(
          opts,
          profile,
          :embedding_dimensions,
          GeminiClient.default_dimensions()
        ),
      embedding_auth: parse_embedding_auth(option(opts, profile, :embedding_auth, nil)),
      bootstrap_resamples: option(opts, profile, :bootstrap_resamples, 2_000),
      baseline_retry_budget: Keyword.get(opts, :baseline_retry_budget, 2),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, 5_000),
      preview_chars: Keyword.get(opts, :preview_chars, 180),
      timeout_ms: Keyword.get(opts, :timeout_ms, 120_000),
      thinking_budget: option(opts, profile, :thinking_budget, 1200),
      verbose: Keyword.get(opts, :verbose, false)
    }
  end

  defp run_benchmark(config) do
    fields = read_fields!(config.fields_path)
    fields_sha256 = sha256_file!(config.fields_path)
    baseline_calls = baseline_call_count(config.baseline)
    frontier_calls = config.branching * config.rounds
    calls_per_run = baseline_calls + frontier_calls + frontier_calls
    planned_llm_calls = length(fields) * config.repetitions * calls_per_run
    validate_budget!(config)

    if config.dry_run do
      emit(
        %{
          "schema_version" => 1,
          "mode" => benchmark_mode(config),
          "dry_run" => true,
          "diagnostic" => config.diagnostic,
          "run" => run_summary(config),
          "fields_path" => config.fields_path,
          "fields_sha256" => fields_sha256,
          "field_count" => length(fields),
          "repetitions" => config.repetitions,
          "baseline_calls_per_run" => baseline_calls,
          "frontier_bursts_per_run" => frontier_calls,
          "matched_baseline_calls_per_run" => frontier_calls,
          "planned_llm_calls" => planned_llm_calls,
          "distance" => config.distance,
          "embedding" => embedding_summary(config),
          "rounds" => config.rounds,
          "frontier_temperature_points" => frontier_temperature_points(config),
          "matched_baseline_temperature_points" => matched_baseline_temperature_points(config)
        },
        config
      )
    else
      if planned_llm_calls > 500 and not config.expensive do
        Mix.raise(
          "planned_llm_calls=#{planned_llm_calls} exceeds safe limit; pass --expensive to run"
        )
      end

      reports =
        config
        |> benchmark_progress_opts()
        |> AntiAgents.Progress.with_heartbeat(:benchmark, fn progress_opts ->
          AntiAgents.Progress.event(progress_opts, :benchmark_plan, %{
            field_count: length(fields),
            repetitions: config.repetitions,
            run_count: length(fields) * config.repetitions,
            planned_llm_calls: planned_llm_calls,
            calls_per_run: calls_per_run
          })

          run_reports(fields, config, progress_opts, calls_per_run, planned_llm_calls)
        end)

      calibration_status = calibration_status(reports)
      hypothesis = aggregate_hypothesis(reports, config, calibration_status)
      pooled_hypothesis = pooled_hypothesis(reports, config)

      emit(
        %{
          "schema_version" => 1,
          "mode" => benchmark_mode(config),
          "diagnostic" => config.diagnostic,
          "run" => run_summary(config),
          "fields_path" => config.fields_path,
          "fields_sha256" => fields_sha256,
          "field_count" => length(fields),
          "repetitions" => config.repetitions,
          "planned_llm_calls" => planned_llm_calls,
          "evidence" => %{
            "hypothesis_test" => hypothesis,
            "pooled_hypothesis_test" => pooled_hypothesis,
            "calibration_status" => calibration_status
          },
          "runs" => Enum.map(reports, &benchmark_run_trace/1)
        },
        config
      )
    end
  end

  defp validate_budget!(%{branching: branching, diagnostic: false}) when branching < 4 do
    Mix.raise(
      "--branching #{branching} is diagnostic-only. Use --branching >= 4 for benchmark reports or pass --diagnostic to mark the output as non-evidence."
    )
  end

  defp validate_budget!(_config), do: :ok

  defp benchmark_mode(%{diagnostic: true}), do: "benchmark_diagnostic"
  defp benchmark_mode(%{dry_run: true}), do: "benchmark_dry_run"
  defp benchmark_mode(_config), do: "benchmark_report"

  defp benchmark_run_trace(%{field_id: field_id, repetition: repetition, trace: trace}) do
    trace
    |> Map.put("field_id", field_id)
    |> Map.put("repetition", repetition)
  end

  defp run_summary(config) do
    %{
      "profile_id" => config.profile_id,
      "profile_path" => config.profile_path,
      "profile_overrides" => config.profile_overrides,
      "model" => config.model,
      "reasoning_effort" => Atom.to_string(config.reasoning_effort),
      "thinking_budget" => config.thinking_budget,
      "branching" => config.branching,
      "repetitions" => config.repetitions,
      "distance" => config.distance,
      "embedding" => embedding_summary(config),
      "frontier_temperature_points" => frontier_temperature_points(config),
      "matched_baseline_temperature_points" => matched_baseline_temperature_points(config)
    }
  end

  defp run_reports(fields, config, progress_opts, calls_per_run, planned_llm_calls) do
    field_count = length(fields)
    run_total = field_count * config.repetitions

    fields
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {field_map, field_index} ->
      for repetition <- 1..config.repetitions do
        run_one_report(field_map, %{
          field_index: field_index,
          field_count: field_count,
          repetition: repetition,
          run_total: run_total,
          config: config,
          progress_opts: progress_opts,
          calls_per_run: calls_per_run,
          planned_llm_calls: planned_llm_calls
        })
      end
    end)
  end

  defp run_one_report(field_map, ctx) do
    field = field_from_map(field_map)
    run_index = (ctx.repetition - 1) * ctx.field_count + ctx.field_index
    field_id = Map.get(field_map, "id", field.prompt)
    llm_offset = (run_index - 1) * ctx.calls_per_run

    benchmark_opts = [
      benchmark_run_index: run_index,
      benchmark_run_total: ctx.run_total,
      benchmark_field_index: ctx.field_index,
      benchmark_field_total: ctx.field_count,
      benchmark_field_id: field_id,
      benchmark_llm_offset: llm_offset,
      benchmark_llm_total: ctx.planned_llm_calls
    ]

    AntiAgents.Progress.event(ctx.progress_opts, :benchmark_run_start, %{
      run_index: run_index,
      run_total: ctx.run_total,
      field_index: ctx.field_index,
      field_total: ctx.field_count,
      field_id: field_id,
      repetition: ctx.repetition,
      repetitions: ctx.config.repetitions,
      llm_done: llm_offset,
      llm_total: ctx.planned_llm_calls,
      calls_this_run: ctx.calls_per_run
    })

    opts =
      [
        branching: ctx.config.branching,
        baseline: ctx.config.baseline,
        matched_baseline_methods: matched_baseline_methods(ctx.config),
        matched_budget: true,
        bootstrap_resamples: ctx.config.bootstrap_resamples,
        baseline_retry_budget: ctx.config.baseline_retry_budget,
        concurrency: ctx.config.concurrency,
        rounds: ctx.config.rounds,
        distance: parse_distance(ctx.config.distance),
        timeout_ms: ctx.config.timeout_ms,
        preview_chars: ctx.config.preview_chars,
        frontier_temperature_sweep: ctx.config.frontier_temperature_sweep,
        model: ctx.config.model,
        reasoning_effort: ctx.config.reasoning_effort,
        thinking_budget: ctx.config.thinking_budget,
        profile_id: ctx.config.profile_id,
        profile_overrides: ctx.config.profile_overrides,
        verbose: ctx.config.verbose,
        progress_state: Keyword.get(ctx.progress_opts, :progress_state),
        heat: [answer: ctx.config.temperature]
      ] ++ benchmark_opts ++ embedding_opts(ctx.config)

    report = AntiAgents.frontier(field, opts)

    AntiAgents.Progress.event(ctx.progress_opts, :benchmark_run_done, %{
      run_index: run_index,
      run_total: ctx.run_total,
      field_id: field_id,
      llm_done: llm_offset + ctx.calls_per_run,
      llm_total: ctx.planned_llm_calls,
      accepted: length(report.exemplars),
      adjusted_novel_frontier_cell_count: report.adjusted_novel_frontier_cell_count
    })

    %{
      field_id: field_id,
      repetition: ctx.repetition,
      report: report,
      trace: AntiAgents.Trace.report(report, opts)
    }
  end

  defp benchmark_progress_opts(config) do
    [
      verbose: config.verbose,
      heartbeat_ms: config.heartbeat_ms,
      preview_chars: config.preview_chars
    ]
  end

  defp aggregate_hypothesis(reports, config, calibration_status) do
    reports
    |> Enum.map(&AntiAgents.Statistics.per_field_delta(&1.report))
    |> AntiAgents.Statistics.evidence_hypothesis(calibration_status,
      resamples: config.bootstrap_resamples,
      seed: 41
    )
  end

  defp pooled_hypothesis(reports, config) do
    frontier = reports |> Enum.flat_map(& &1.report.exemplars)
    matched = reports |> Enum.flat_map(& &1.report.matched_baseline_archive)

    AntiAgents.Statistics.hypothesis_test(frontier, matched,
      resamples: config.bootstrap_resamples,
      seed: 41
    )
  end

  defp calibration_status(reports) do
    saturated =
      Enum.count(reports, fn run ->
        Map.get(run.report.metrics, :cell_saturation_warning, false)
      end)

    if reports != [] and saturated / length(reports) > 0.3 do
      "descriptor_saturated"
    else
      "ok"
    end
  end

  defp emit(data, config) do
    case config.out do
      nil ->
        Mix.shell().info(Jason.encode!(data, pretty: true))

      path ->
        AntiAgents.Trace.write_json!(path, data)
        Mix.shell().info("Wrote AntiAgents benchmark trace to #{path}")
    end
  end

  defp load_profile(nil), do: %{}

  defp load_profile(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp option(opts, profile, key, default) do
    Keyword.get(opts, key, Map.get(profile, Atom.to_string(key), default))
  end

  defp profile_overrides(_opts, profile) when profile == %{}, do: %{}

  defp profile_overrides(opts, profile) do
    profile_keys = profile |> Map.keys() |> MapSet.new()

    opts
    |> Enum.flat_map(fn
      {:reasoning, value} ->
        if MapSet.member?(profile_keys, "reasoning_effort"),
          do: [{"reasoning_effort", value}],
          else: []

      {key, value} ->
        profile_key = Atom.to_string(key)

        if MapSet.member?(profile_keys, profile_key),
          do: [{profile_key, value}],
          else: []
    end)
    |> Map.new()
  end

  defp read_fields!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp sha256_file!(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp field_from_map(map) do
    axes =
      map
      |> Map.get("axes", [])
      |> Enum.map(&String.to_atom/1)

    AntiAgents.field(Map.fetch!(map, "prompt"),
      axes: axes,
      toward: Map.get(map, "toward", []),
      away_from: Map.get(map, "away_from", [])
    )
  end

  defp parse_baseline(nil),
    do: [:plain, :paraphrase, {:temperature, [0.8, 1.0, 1.2]}, :seed_injection]

  defp parse_baseline(methods) when is_list(methods) do
    Enum.flat_map(methods, fn
      method when is_binary(method) ->
        parse_baseline_entry(method)

      %{"temperature" => temps} when is_list(temps) ->
        [{:temperature, Enum.map(temps, &(&1 * 1.0))}]

      other when is_atom(other) ->
        [other]

      _other ->
        []
    end)
  end

  defp parse_baseline(text) when is_binary(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.flat_map(&parse_baseline_entry/1)
  end

  defp parse_baseline_entry("plain"), do: [:plain]
  defp parse_baseline_entry("paraphrase"), do: [:paraphrase]
  defp parse_baseline_entry("seed_injection"), do: [:seed_injection]
  defp parse_baseline_entry("temp:" <> temps), do: [{:temperature, parse_temps(temps)}]
  defp parse_baseline_entry("temperature:" <> temps), do: [{:temperature, parse_temps(temps)}]
  defp parse_baseline_entry(_unknown), do: []

  defp parse_temps(temps),
    do: temps |> String.split("|", trim: true) |> Enum.map(&String.to_float/1)

  defp parse_temperature_sweep(nil), do: []
  defp parse_temperature_sweep(""), do: []
  defp parse_temperature_sweep(values) when is_list(values), do: Enum.map(values, &(&1 * 1.0))
  defp parse_temperature_sweep(text), do: parse_temps(text)

  defp frontier_temperature_points(%{frontier_temperature_sweep: []} = config),
    do: [config.temperature]

  defp frontier_temperature_points(config), do: config.frontier_temperature_sweep

  defp matched_baseline_methods(%{frontier_temperature_sweep: []} = config),
    do: [{:temperature, [config.temperature]}]

  defp matched_baseline_methods(config), do: config.baseline

  defp matched_baseline_temperature_points(config) do
    config
    |> matched_baseline_methods()
    |> Enum.flat_map(fn
      {:temperature, temps} when is_list(temps) -> temps
      {:temperature, temp} when is_number(temp) -> [temp]
      _method -> []
    end)
  end

  defp embedding_opts(%{distance: "embedding"} = config) do
    [
      embedding_client: GeminiClient,
      embedding_model: config.embedding_model,
      embedding_task_type: config.embedding_task_type,
      embedding_dimensions: config.embedding_dimensions
    ]
    |> maybe_embedding_auth(config.embedding_auth)
  end

  defp embedding_opts(_config), do: []

  defp embedding_summary(%{distance: "embedding"} = config) do
    %{
      "client" => "gemini_ex",
      "model" => config.embedding_model,
      "task_type" => Atom.to_string(config.embedding_task_type),
      "dimensions" => config.embedding_dimensions,
      "auth" => if(config.embedding_auth, do: Atom.to_string(config.embedding_auth), else: nil)
    }
  end

  defp embedding_summary(_config), do: nil

  defp maybe_embedding_auth(opts, nil), do: opts
  defp maybe_embedding_auth(opts, auth), do: Keyword.put(opts, :embedding_auth, auth)

  defp parse_embedding_auth("gemini"), do: :gemini
  defp parse_embedding_auth("vertex_ai"), do: :vertex_ai
  defp parse_embedding_auth(_other), do: nil

  defp parse_distance("embedding"), do: :embedding
  defp parse_distance("judge"), do: :judge
  defp parse_distance(_other), do: :jaccard

  defp baseline_call_count(methods) do
    methods
    |> Enum.flat_map(fn
      {:temperature, temps} when is_list(temps) -> temps
      _method -> [1]
    end)
    |> length()
  end
end
