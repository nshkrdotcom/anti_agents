defmodule Mix.Tasks.AntiAgents.Benchmark do
  @moduledoc """
  Run a matched-budget AntiAgents benchmark across a fields JSON file.
  """

  use Mix.Task

  @shortdoc "Runs a matched-budget AntiAgents benchmark"

  @switches [
    fields: :string,
    out: :string,
    dry_run: :boolean,
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
      --branching N             frontier bursts per field/repetition, default 8
      --repetitions N           repetitions per field, default 3
      --baseline LIST           plain,paraphrase,seed_injection,temp:0.8|1.0|1.2
      --bootstrap-resamples N   default 2000
      --heartbeat-ms N          verbose heartbeat interval, default 5000
      --preview-chars N         chars of prompt/output preview, default 180
      --out PATH                write JSON report to PATH
      --expensive               allow large planned call counts
    """
  end

  defp normalize_opts(opts) do
    fields = Keyword.get(opts, :fields) || Mix.raise("--fields is required")

    %{
      fields_path: fields,
      out: Keyword.get(opts, :out),
      dry_run: Keyword.get(opts, :dry_run, false),
      expensive: Keyword.get(opts, :expensive, false),
      branching: Keyword.get(opts, :branching, 8),
      repetitions: Keyword.get(opts, :repetitions, 3),
      concurrency: Keyword.get(opts, :concurrency, System.schedulers_online()),
      rounds: Keyword.get(opts, :rounds, 1),
      distance: Keyword.get(opts, :distance, "jaccard"),
      baseline: parse_baseline(Keyword.get(opts, :baseline)),
      model: Keyword.get(opts, :model, AntiAgents.CodexConfig.default_model()),
      reasoning_effort:
        opts
        |> Keyword.get(:reasoning, AntiAgents.CodexConfig.default_reasoning_effort())
        |> AntiAgents.CodexConfig.normalize_reasoning_effort(),
      temperature: Keyword.get(opts, :temperature, 1.05),
      bootstrap_resamples: Keyword.get(opts, :bootstrap_resamples, 2_000),
      baseline_retry_budget: Keyword.get(opts, :baseline_retry_budget, 2),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, 5_000),
      preview_chars: Keyword.get(opts, :preview_chars, 180),
      timeout_ms: Keyword.get(opts, :timeout_ms, 120_000),
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

    if config.dry_run do
      emit(
        %{
          "schema_version" => 1,
          "mode" => "benchmark_dry_run",
          "fields_path" => config.fields_path,
          "fields_sha256" => fields_sha256,
          "field_count" => length(fields),
          "repetitions" => config.repetitions,
          "baseline_calls_per_run" => baseline_calls,
          "frontier_bursts_per_run" => frontier_calls,
          "matched_baseline_calls_per_run" => frontier_calls,
          "planned_llm_calls" => planned_llm_calls,
          "distance" => config.distance,
          "rounds" => config.rounds
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

      hypothesis = aggregate_hypothesis(reports, config)

      emit(
        %{
          "schema_version" => 1,
          "mode" => "benchmark_report",
          "fields_path" => config.fields_path,
          "fields_sha256" => fields_sha256,
          "field_count" => length(fields),
          "repetitions" => config.repetitions,
          "planned_llm_calls" => planned_llm_calls,
          "evidence" => %{"hypothesis_test" => hypothesis},
          "runs" => Enum.map(reports, & &1.trace)
        },
        config
      )
    end
  end

  defp run_reports(fields, config, progress_opts, calls_per_run, planned_llm_calls) do
    field_count = length(fields)
    run_total = field_count * config.repetitions

    fields
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {field_map, field_index} ->
      for repetition <- 1..config.repetitions do
        run_one_report(
          field_map,
          field_index,
          field_count,
          repetition,
          run_total,
          config,
          progress_opts,
          calls_per_run,
          planned_llm_calls
        )
      end
    end)
  end

  defp run_one_report(
         field_map,
         field_index,
         field_count,
         repetition,
         run_total,
         config,
         progress_opts,
         calls_per_run,
         planned_llm_calls
       ) do
    field = field_from_map(field_map)
    run_index = (repetition - 1) * field_count + field_index
    field_id = Map.get(field_map, "id", field.prompt)
    llm_offset = (run_index - 1) * calls_per_run

    benchmark_opts = [
      benchmark_run_index: run_index,
      benchmark_run_total: run_total,
      benchmark_field_index: field_index,
      benchmark_field_total: field_count,
      benchmark_field_id: field_id,
      benchmark_llm_offset: llm_offset,
      benchmark_llm_total: planned_llm_calls
    ]

    AntiAgents.Progress.event(progress_opts, :benchmark_run_start, %{
      run_index: run_index,
      run_total: run_total,
      field_index: field_index,
      field_total: field_count,
      field_id: field_id,
      repetition: repetition,
      repetitions: config.repetitions,
      llm_done: llm_offset,
      llm_total: planned_llm_calls,
      calls_this_run: calls_per_run
    })

    opts =
      [
        branching: config.branching,
        baseline: config.baseline,
        matched_budget: true,
        bootstrap_resamples: config.bootstrap_resamples,
        baseline_retry_budget: config.baseline_retry_budget,
        concurrency: config.concurrency,
        rounds: config.rounds,
        distance: parse_distance(config.distance),
        timeout_ms: config.timeout_ms,
        preview_chars: config.preview_chars,
        model: config.model,
        reasoning_effort: config.reasoning_effort,
        verbose: config.verbose,
        progress_state: Keyword.get(progress_opts, :progress_state),
        heat: [answer: config.temperature]
      ] ++ benchmark_opts

    report = AntiAgents.frontier(field, opts)

    AntiAgents.Progress.event(progress_opts, :benchmark_run_done, %{
      run_index: run_index,
      run_total: run_total,
      field_id: field_id,
      llm_done: llm_offset + calls_per_run,
      llm_total: planned_llm_calls,
      accepted: length(report.exemplars),
      adjusted_novel_frontier_cell_count: report.adjusted_novel_frontier_cell_count
    })

    %{
      field_id: field_id,
      repetition: repetition,
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

  defp aggregate_hypothesis(reports, config) do
    frontier = reports |> Enum.flat_map(& &1.report.exemplars)
    matched = reports |> Enum.flat_map(& &1.report.matched_baseline_archive)

    AntiAgents.Statistics.hypothesis_test(frontier, matched,
      resamples: config.bootstrap_resamples,
      seed: 41
    )
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
