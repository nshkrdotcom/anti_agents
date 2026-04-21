defmodule AntiAgents.Statistics do
  @moduledoc """
  Statistical helpers for matched-budget frontier evaluation.

  The functions here intentionally operate on already-materialized burst
  structs. They do not call providers; they only count descriptor cells and
  bootstrap observed archive differences.
  """

  alias AntiAgents.BurstResult

  @type ci :: {float(), float()}

  @doc """
  Counts unique descriptor cells among bursts that have a descriptor.
  """
  @spec distinct_cell_count([BurstResult.t() | map()]) :: non_neg_integer()
  def distinct_cell_count(bursts) when is_list(bursts) do
    bursts
    |> Enum.flat_map(fn
      %{descriptor: %{cell: cell}} when not is_nil(cell) -> [cell]
      _other -> []
    end)
    |> MapSet.new()
    |> MapSet.size()
  end

  @doc """
  Computes a percentile bootstrap confidence interval.

  `statistic_fun` receives each resampled list and must return a number.
  """
  @spec bootstrap_ci([term()], (list() -> number()), keyword()) :: ci()
  def bootstrap_ci(samples, statistic_fun, opts)
      when is_list(samples) and is_function(statistic_fun, 1) do
    resamples = Keyword.get(opts, :resamples, 2_000)
    confidence = Keyword.get(opts, :confidence, 0.95)
    seed = Keyword.get(opts, :seed, 1)

    if samples == [] or resamples <= 0 do
      {0.0, 0.0}
    else
      {_rng, values} =
        Enum.reduce(1..resamples, {seed_rng(seed), []}, fn _index, {rng, acc} ->
          {rng, sample} = resample(samples, length(samples), rng)
          {rng, [statistic_fun.(sample) * 1.0 | acc]}
        end)

      sorted = Enum.sort(values)
      alpha = (1.0 - confidence) / 2.0
      {percentile(sorted, alpha), percentile(sorted, 1.0 - alpha)}
    end
  end

  @doc """
  Compares frontier cells against an equal-sized matched baseline sample.
  """
  @spec hypothesis_test([BurstResult.t()], [BurstResult.t()], keyword()) :: map()
  def hypothesis_test(frontier, matched_baseline, opts \\ []) do
    resamples = Keyword.get(opts, :resamples, 2_000)
    seed = Keyword.get(opts, :seed, 1)
    frontier_count = distinct_cell_count(frontier)
    matched_count = distinct_cell_count(matched_baseline)
    delta = frontier_count - matched_count

    {lo, hi} =
      bootstrap_delta_ci(frontier, matched_baseline, resamples: resamples, seed: seed)

    %{
      delta_distinct_cells: delta,
      bootstrap_ci_95: [lo, hi],
      rejects_null: lo > 0,
      matched_baseline_cell_count: matched_count,
      frontier_cell_count: frontier_count,
      n_resamples: resamples
    }
  end

  @doc """
  Extracts the per-field delta from a frontier report or benchmark run map.
  """
  @spec per_field_delta(map()) :: integer()
  def per_field_delta(%{report: report}), do: per_field_delta(report)

  def per_field_delta(%{hypothesis_test: %{delta_distinct_cells: delta}}) when is_integer(delta),
    do: delta

  def per_field_delta(%{hypothesis_test: %{"delta_distinct_cells" => delta}})
      when is_integer(delta),
      do: delta

  def per_field_delta(%{exemplars: frontier, matched_baseline_archive: matched})
      when is_list(frontier) and is_list(matched),
      do: distinct_cell_count(frontier) - distinct_cell_count(matched)

  @doc """
  Bootstraps the mean per-field delta.
  """
  @spec mean_delta_ci([number()], keyword()) :: map()
  def mean_delta_ci(deltas, opts \\ []) when is_list(deltas) do
    resamples = Keyword.get(opts, :resamples, 2_000)
    seed = Keyword.get(opts, :seed, 1)
    mean_delta = mean(deltas)
    {lo, hi} = bootstrap_ci(deltas, &mean/1, resamples: resamples, seed: seed)

    %{
      mean_delta: mean_delta,
      bootstrap_ci_95: [lo, hi],
      n_observations: length(deltas),
      n_resamples: resamples
    }
  end

  @doc """
  One-sided sign test for H0 median(delta) <= 0.

  Zeros are recorded but excluded from the binomial test.
  """
  @spec sign_test([number()]) :: map()
  def sign_test(deltas) when is_list(deltas) do
    positives = Enum.count(deltas, &(&1 > 0))
    negatives = Enum.count(deltas, &(&1 < 0))
    zeros = Enum.count(deltas, &(&1 == 0))
    trials = positives + negatives

    p_value =
      if trials == 0 do
        1.0
      else
        positives..trials
        |> Enum.map(&binomial_probability(trials, &1))
        |> Enum.sum()
        |> min(1.0)
      end

    %{
      positives: positives,
      negatives: negatives,
      zeros: zeros,
      trials: trials,
      p_value: Float.round(p_value, 6)
    }
  end

  @spec bootstrap_delta_ci([BurstResult.t()], [BurstResult.t()], keyword()) :: ci()
  def bootstrap_delta_ci(frontier, matched_baseline, opts) do
    resamples = Keyword.get(opts, :resamples, 2_000)
    seed = Keyword.get(opts, :seed, 1)

    cond do
      resamples <= 0 ->
        delta = distinct_cell_count(frontier) - distinct_cell_count(matched_baseline)
        {delta * 1.0, delta * 1.0}

      frontier == [] and matched_baseline == [] ->
        {0.0, 0.0}

      true ->
        {_rng, values} =
          Enum.reduce(1..resamples, {seed_rng(seed), []}, fn _index, {rng, acc} ->
            {rng, frontier_sample} = resample(frontier, length(frontier), rng)
            {rng, matched_sample} = resample(matched_baseline, length(matched_baseline), rng)

            delta = distinct_cell_count(frontier_sample) - distinct_cell_count(matched_sample)
            {rng, [delta * 1.0 | acc]}
          end)

        sorted = Enum.sort(values)
        {percentile(sorted, 0.025), percentile(sorted, 0.975)}
    end
  end

  defp resample(_samples, 0, rng), do: {rng, []}

  defp resample(samples, count, rng) do
    Enum.reduce(1..count, {rng, []}, fn _index, {rng, acc} ->
      {rng, offset} = next_index(rng, length(samples))
      {rng, [Enum.at(samples, offset) | acc]}
    end)
  end

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)

  defp binomial_probability(n, k) do
    combination(n, k) * :math.pow(0.5, n)
  end

  defp combination(n, k) do
    k = min(k, n - k)

    if k == 0 do
      1.0
    else
      1..k
      |> Enum.reduce(1.0, fn i, acc -> acc * (n - k + i) / i end)
    end
  end

  defp seed_rng(seed) when is_integer(seed), do: rem(abs(seed), 2_147_483_647)
  defp seed_rng(seed), do: seed |> :erlang.phash2() |> seed_rng()

  defp next_index(rng, size) do
    next = rem(rng * 48_271, 2_147_483_647)
    {next, rem(next, max(1, size))}
  end

  defp percentile([], _p), do: 0.0

  defp percentile(sorted, p) do
    index =
      ((length(sorted) - 1) * p)
      |> Float.round()
      |> trunc()
      |> min(length(sorted) - 1)
      |> max(0)

    Enum.at(sorted, index) * 1.0
  end
end
