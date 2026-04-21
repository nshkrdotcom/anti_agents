defmodule Mix.Tasks.AntiAgents.Ablate do
  @moduledoc """
  Re-score a reference benchmark trace under descriptor ablation modes.

  This task is intentionally offline. It reads already-recorded bursts from a
  reference trace and never calls Codex, Gemini, or any other provider.
  """

  use Mix.Task

  @shortdoc "Runs offline descriptor ablation against a reference trace"

  @switches [
    fields: :string,
    branching: :integer,
    repetitions: :integer,
    reference_trace: :string,
    modes: :string,
    out: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        opts
        |> normalize_opts()
        |> run_ablation()

      {_opts, _args, invalid} ->
        Mix.raise("Invalid options: #{inspect(invalid)}\n\n#{usage()}")
    end
  end

  defp usage do
    """
    Usage:
      mix anti_agents.ablate --reference-trace tmp/evidence.json [options]

    Options:
      --fields PATH             optional fields JSON for provenance
      --branching N             optional expected branching for provenance
      --repetitions N           optional expected repetitions for provenance
      --modes LIST              jaccard,embedding or one mode; default jaccard,embedding
      --out PATH                output path; default tmp/anti_agents_ablation_<date>.json
    """
  end

  defp normalize_opts(opts) do
    %{
      fields_path: Keyword.get(opts, :fields),
      branching: Keyword.get(opts, :branching),
      repetitions: Keyword.get(opts, :repetitions),
      reference_trace:
        Keyword.get(opts, :reference_trace) || Mix.raise("--reference-trace is required"),
      modes: parse_modes(Keyword.get(opts, :modes, "jaccard,embedding")),
      out: Keyword.get(opts, :out, default_out_path())
    }
  end

  defp parse_modes(value) do
    modes =
      value
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(fn
        "jaccard" ->
          "jaccard"

        "embedding" ->
          "embedding"

        other ->
          Mix.raise("invalid ablation mode #{inspect(other)}; expected jaccard or embedding")
      end)
      |> Enum.uniq()

    if modes == [] do
      Mix.raise("--modes must include at least one mode")
    else
      modes
    end
  end

  defp run_ablation(config) do
    trace = config.reference_trace |> File.read!() |> Jason.decode!()
    runs = reference_runs(trace)
    ablated_runs = Enum.map(runs, &ablate_run(&1, config.modes))

    report = %{
      "schema_version" => 1,
      "mode" => "ablation_report",
      "reference_trace" => config.reference_trace,
      "fields_path" => config.fields_path,
      "fields_sha256" => fields_sha256(config.fields_path),
      "branching" => config.branching,
      "repetitions" => config.repetitions,
      "modes" => config.modes,
      "provider_calls" => 0,
      "run_count" => length(ablated_runs),
      "runs" => ablated_runs,
      "summary" => summary(ablated_runs, config.modes)
    }

    AntiAgents.Trace.write_json!(config.out, report)
    Mix.shell().info("Wrote AntiAgents ablation trace to #{config.out}")
  end

  defp reference_runs(%{"runs" => runs}) when is_list(runs), do: runs
  defp reference_runs(%{"mode" => "frontier_report"} = run), do: [run]

  defp reference_runs(_trace) do
    Mix.raise("--reference-trace must be a benchmark report with runs or a frontier_report")
  end

  defp ablate_run(run, modes) do
    mode_results =
      modes
      |> Enum.map(fn mode -> {mode, mode_result(run, mode)} end)
      |> Map.new()

    deltas =
      mode_results
      |> Enum.map(fn {mode, result} -> {"delta_#{mode}", result.delta} end)
      |> Map.new()

    %{
      "field_id" => Map.get(run, "field_id", get_in(run, ["field", "prompt"])),
      "repetition" => Map.get(run, "repetition"),
      "directional_agreement" => directional_agreement(mode_results, modes)
    }
    |> Map.merge(deltas)
    |> Map.put("cells", cells_by_mode(mode_results))
  end

  defp mode_result(run, mode) do
    frontier_count = cell_count(Map.get(run, "exemplars", []), mode)
    matched_count = cell_count(Map.get(run, "matched_baseline_archive", []), mode)

    %{
      frontier_cells: frontier_count,
      matched_baseline_cells: matched_count,
      delta: frontier_count - matched_count
    }
  end

  defp cell_count(archive, mode) when is_list(archive) do
    archive
    |> Enum.flat_map(&cell_for(&1, mode))
    |> MapSet.new()
    |> MapSet.size()
  end

  defp cell_for(%{"descriptor" => %{"cell" => cell}}, mode) when is_map(cell) do
    [normalize_cell(cell, mode)]
  end

  defp cell_for(_burst, _mode), do: []

  defp normalize_cell(cell, "embedding") do
    cell
    |> Map.put_new("semantic_cluster", "unknown")
    |> ordered_cell()
  end

  defp normalize_cell(cell, "jaccard") do
    cell
    |> Map.put("semantic_cluster", "unknown")
    |> ordered_cell()
  end

  defp ordered_cell(cell) do
    cell
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> :erlang.term_to_binary()
  end

  defp directional_agreement(_mode_results, [_single_mode]), do: nil

  defp directional_agreement(mode_results, [first, second | _rest]) do
    sign(mode_results[first].delta) == sign(mode_results[second].delta)
  end

  defp sign(value) when value > 0, do: 1
  defp sign(value) when value < 0, do: -1
  defp sign(_value), do: 0

  defp cells_by_mode(mode_results) do
    mode_results
    |> Enum.map(fn {mode, result} ->
      {mode,
       %{
         "frontier" => result.frontier_cells,
         "matched_baseline" => result.matched_baseline_cells
       }}
    end)
    |> Map.new()
  end

  defp summary(runs, modes) do
    agreements =
      runs
      |> Enum.map(&Map.get(&1, "directional_agreement"))
      |> Enum.reject(&is_nil/1)

    mode_means =
      modes
      |> Enum.map(fn mode -> {"mean_delta_#{mode}", mean_delta(runs, mode)} end)
      |> Map.new()

    %{
      "directional_agreement" => agreement_rate(agreements),
      "sign_disagreement_count" => Enum.count(agreements, &(&1 == false)),
      "directional_agreement_bar" => 0.7,
      "passes_directional_agreement_bar" => passes_agreement_bar?(agreements)
    }
    |> Map.merge(mode_means)
  end

  defp mean_delta([], _mode), do: 0.0

  defp mean_delta(runs, mode) do
    values = Enum.map(runs, &Map.get(&1, "delta_#{mode}", 0))
    Enum.sum(values) / length(values)
  end

  defp agreement_rate([]), do: nil

  defp agreement_rate(agreements) do
    agreements
    |> Enum.count(&(&1 == true))
    |> Kernel./(length(agreements))
    |> Float.round(3)
  end

  defp passes_agreement_bar?([]), do: nil
  defp passes_agreement_bar?(agreements), do: agreement_rate(agreements) >= 0.7

  defp fields_sha256(nil), do: nil

  defp fields_sha256(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    else
      nil
    end
  end

  defp default_out_path do
    "tmp/anti_agents_ablation_#{Date.utc_today()}.json"
  end
end
