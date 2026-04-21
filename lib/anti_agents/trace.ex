defmodule AntiAgents.Trace do
  @moduledoc false

  alias AntiAgents.{BurstResult, Field, FrontierReport}

  def dry_run(prompt, opts) do
    %{
      "schema_version" => 1,
      "mode" => "dry_run",
      "synthesis" => synthesis(),
      "field" => %{
        "prompt" => prompt,
        "toward" => get_in(opts, [:field, :toward]) || [],
        "away_from" => get_in(opts, [:field, :away_from]) || []
      },
      "run" => run(opts)
    }
  end

  def report(%FrontierReport{} = report, opts \\ []) do
    include_raw = Keyword.get(opts, :include_raw, false)

    %{
      "schema_version" => 1,
      "mode" => "frontier_report",
      "synthesis" => synthesis(),
      "field" => field(report.field),
      "run" => run(opts),
      "metrics" => json_safe(report.metrics),
      "evidence" => evidence(report),
      "frontier_cell_count" => report.frontier_cell_count,
      "reachable_cell_count" => report.reachable_cell_count,
      "novel_frontier_cell_count" => report.novel_frontier_cell_count,
      "coverage_delta" => report.coverage_delta,
      "reachable_archive" => Enum.map(report.reachable_archive, &burst(&1, include_raw)),
      "exemplars" => Enum.map(report.exemplars, &burst(&1, include_raw)),
      "rejected_duplicates" => Enum.map(report.rejected_duplicates, &burst(&1, include_raw)),
      "reachable_hits" => json_safe(report.reachable_hits),
      "mapping_traces" => json_safe(report.mapping_traces)
    }
  end

  def write_json!(path, data) when is_binary(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(data, pretty: true))
    path
  end

  defp synthesis do
    %{
      "essential_aspect" =>
        "entropy-first generation with visible local coordinate mapping plus archive pressure",
      "claim_under_test" =>
        "SSoT-style random strings become useful when each chunk is mapped to exploration axes and then filtered against reachable baseline cells.",
      "anti_collapse_checks" => [
        "reject low seed coverage",
        "penalize prefix-only chunk use",
        "separate reachable baseline archive from frontier archive",
        "retain mapping traces for audit"
      ]
    }
  end

  defp run(opts) do
    %{
      "model" => AntiAgents.CodexConfig.model(opts),
      "reasoning_effort" => Atom.to_string(AntiAgents.CodexConfig.reasoning_effort(opts)),
      "temperature" => AntiAgents.Prompt.response_temperature(opts),
      "branching" => Keyword.get(opts, :branching, 8),
      "baseline" => json_safe(Keyword.get(opts, :baseline, [])),
      "coordinate" => json_safe(Keyword.get(opts, :coordinate, [])),
      "thinking_budget" => Keyword.get(opts, :thinking_budget, 1200)
    }
  end

  defp field(%Field{} = field) do
    %{
      "prompt" => field.prompt,
      "axes" => Enum.map(field.axes, &Atom.to_string/1),
      "toward" => field.toward,
      "away_from" => field.away_from
    }
  end

  defp burst(%BurstResult{} = burst, include_raw) do
    %{
      "status" => Atom.to_string(burst.status),
      "rejection_reason" => burst.rejection_reason,
      "seed" => burst.seed,
      "random_string" => burst.random_string,
      "mapping_trace" => json_safe(burst.mapping_trace),
      "mapping_verification" => json_safe(burst.mapping_verification),
      "answer" => burst.answer,
      "descriptor" => json_safe(burst.descriptor),
      "score" => json_safe(burst.score),
      "coherence" => burst.coherence,
      "seed_coverage" => burst.seed_coverage
    }
    |> maybe_put_raw(burst.raw_output, include_raw)
  end

  defp maybe_put_raw(map, _raw_output, false), do: map
  defp maybe_put_raw(map, raw_output, true), do: Map.put(map, "raw_output", raw_output)

  defp evidence(%FrontierReport{} = report) do
    accepted_count = length(report.exemplars)
    rejected_count = length(report.rejected_duplicates)
    seed_coverage = Map.get(report.metrics, :seed_coverage, 0.0)

    %{
      "meaningful_signal" =>
        accepted_count > 0 and report.novel_frontier_cell_count > 0 and seed_coverage >= 0.5,
      "accepted_frontier_count" => accepted_count,
      "reachable_baseline_count" => length(report.reachable_archive),
      "rejected_duplicate_or_reachable_count" => rejected_count,
      "mapping_trace_count" => length(report.mapping_traces),
      "delta_frontier" => report.delta_frontier,
      "frontier_cell_count" => report.frontier_cell_count,
      "reachable_cell_count" => report.reachable_cell_count,
      "novel_frontier_cell_count" => report.novel_frontier_cell_count,
      "coverage_delta" => report.coverage_delta,
      "schema_rejected_count" => report.schema_rejected_count,
      "invalid_mapping_count" => report.invalid_mapping_count,
      "duplicate_random_string_count" => report.duplicate_random_string_count,
      "mean_seed_coverage" => seed_coverage,
      "interpretation" =>
        interpretation(accepted_count, report.novel_frontier_cell_count, seed_coverage)
    }
  end

  defp interpretation(accepted_count, delta, coverage)
       when accepted_count > 0 and delta > 0 and coverage >= 0.5 do
    "frontier found non-reachable accepted cells with usable seed coverage"
  end

  defp interpretation(_accepted_count, _delta, _coverage) do
    "insufficient evidence yet; increase branching or inspect rejection reasons"
  end

  defp json_safe(%_{} = struct), do: struct |> Map.from_struct() |> json_safe()

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {json_safe_key(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> json_safe()
  end

  defp json_safe(value) when is_boolean(value), do: value
  defp json_safe(nil), do: nil
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(other), do: other

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key), do: key
end
