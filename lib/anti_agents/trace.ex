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
      "run" => run(opts, report),
      "metrics" => json_safe(report.metrics),
      "evidence" => evidence(report),
      "frontier_cell_count" => report.frontier_cell_count,
      "reachable_cell_count" => report.reachable_cell_count,
      "novel_frontier_cell_count" => report.novel_frontier_cell_count,
      "adjusted_novel_frontier_cell_count" => report.adjusted_novel_frontier_cell_count,
      "coverage_delta" => report.coverage_delta,
      "baseline_retry_count" => report.baseline_retry_count,
      "baseline_permanent_loss_count" => report.baseline_permanent_loss_count,
      "baseline_loss_adjustment" => report.baseline_loss_adjustment,
      "matched_baseline_cell_count" => report.matched_baseline_cell_count,
      "matched_baseline_retry_count" => report.matched_baseline_retry_count,
      "matched_baseline_permanent_loss_count" => report.matched_baseline_permanent_loss_count,
      "matched_baseline_loss_adjustment" => report.matched_baseline_loss_adjustment,
      "adjusted_matched_baseline_cell_count" => report.adjusted_matched_baseline_cell_count,
      "hypothesis_test" => json_safe(report.hypothesis_test),
      "rounds" => report.rounds,
      "round_summaries" => json_safe(report.round_summaries),
      "stagnation_at_round" => report.stagnation_at_round,
      "reachable_archive" => Enum.map(report.reachable_archive, &burst(&1, include_raw)),
      "matched_baseline_archive" =>
        Enum.map(report.matched_baseline_archive, &burst(&1, include_raw)),
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

  defp run(opts), do: run(opts, nil)

  defp run(opts, report) do
    %{
      "model" => AntiAgents.CodexConfig.model(opts),
      "reasoning_effort" => Atom.to_string(AntiAgents.CodexConfig.reasoning_effort(opts)),
      "profile_id" => Keyword.get(opts, :profile_id),
      "profile_overrides" => json_safe(Keyword.get(opts, :profile_overrides, %{})),
      "temperature" => AntiAgents.Prompt.response_temperature(opts),
      "frontier_temperature_points" => frontier_temperature_points(opts),
      "matched_baseline_temperature_points" => matched_baseline_temperature_points(opts),
      "ignored_heat_phases" => ignored_heat_phases(opts),
      "branching" => Keyword.get(opts, :branching, 8),
      "baseline" => json_safe(Keyword.get(opts, :baseline, [])),
      "coordinate" => json_safe(Keyword.get(opts, :coordinate, [])),
      "thinking_budget" => Keyword.get(opts, :thinking_budget, 1200),
      "semantic_descriptor_status" => semantic_descriptor_status(report),
      "semantic_centroid_ids" => semantic_centroid_ids(report)
    }
  end

  defp semantic_descriptor_status(%FrontierReport{} = report),
    do: Atom.to_string(report.semantic_descriptor_status)

  defp semantic_descriptor_status(_report), do: "unknown"

  defp semantic_centroid_ids(%FrontierReport{} = report), do: report.semantic_centroid_ids
  defp semantic_centroid_ids(_report), do: []

  defp frontier_temperature_points(opts) do
    case Keyword.get(opts, :frontier_temperature_sweep, []) do
      [] -> [AntiAgents.Prompt.response_temperature(opts)]
      temperatures -> temperatures
    end
  end

  defp matched_baseline_temperature_points(opts) do
    opts
    |> Keyword.get(:matched_baseline_methods, [])
    |> List.wrap()
    |> Enum.flat_map(fn
      {:temperature, temps} when is_list(temps) -> temps
      {:temperature, temp} when is_number(temp) -> [temp]
      _method -> []
    end)
  end

  defp ignored_heat_phases(opts) do
    heat = Keyword.get(opts, :heat, [])
    seed = heat_value(heat, :seed, 1.3)
    assembly = heat_value(heat, :assembly, 1.15)

    []
    |> maybe_add_ignored_phase(:seed, seed, 1.3)
    |> maybe_add_ignored_phase(:assembly, assembly, 1.15)
    |> Enum.map(&Atom.to_string/1)
  end

  defp heat_value(heat, key, default) when is_list(heat), do: Keyword.get(heat, key, default)
  defp heat_value(heat, key, default) when is_map(heat), do: Map.get(heat, key, default)
  defp heat_value(_heat, _key, default), do: default

  defp maybe_add_ignored_phase(phases, _phase, value, default) when value == default, do: phases
  defp maybe_add_ignored_phase(phases, phase, _value, _default), do: [phase | phases]

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
      "accepted_frontier_count" => accepted_count,
      "reachable_baseline_count" => length(report.reachable_archive),
      "rejected_duplicate_or_reachable_count" => rejected_count,
      "mapping_trace_count" => length(report.mapping_traces),
      "hypothesis_test" => json_safe(report.hypothesis_test),
      "frontier_cell_count" => report.frontier_cell_count,
      "reachable_cell_count" => report.reachable_cell_count,
      "novel_frontier_cell_count" => report.novel_frontier_cell_count,
      "adjusted_novel_frontier_cell_count" => report.adjusted_novel_frontier_cell_count,
      "matched_baseline_cell_count" => report.matched_baseline_cell_count,
      "matched_baseline_retry_count" => report.matched_baseline_retry_count,
      "matched_baseline_permanent_loss_count" => report.matched_baseline_permanent_loss_count,
      "matched_baseline_loss_adjustment" => report.matched_baseline_loss_adjustment,
      "adjusted_matched_baseline_cell_count" => report.adjusted_matched_baseline_cell_count,
      "rounds" => report.rounds,
      "round_summaries" => json_safe(report.round_summaries),
      "stagnation_at_round" => report.stagnation_at_round,
      "coverage_delta" => report.coverage_delta,
      "baseline_retry_count" => report.baseline_retry_count,
      "baseline_permanent_loss_count" => report.baseline_permanent_loss_count,
      "baseline_loss_adjustment" => report.baseline_loss_adjustment,
      "schema_rejected_count" => report.schema_rejected_count,
      "invalid_mapping_count" => report.invalid_mapping_count,
      "duplicate_random_string_count" => report.duplicate_random_string_count,
      "empirical_cell_space" => Map.get(report.metrics, :empirical_cell_space, 0),
      "saturation" => Map.get(report.metrics, :saturation, 0.0),
      "cell_saturation_warning" => Map.get(report.metrics, :cell_saturation_warning, false),
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
