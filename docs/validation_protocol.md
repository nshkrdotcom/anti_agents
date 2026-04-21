# Validation Protocol

AntiAgents uses a matched-budget benchmark to test whether SSoT frontier bursts
occupy descriptor cells beyond an equal-budget baseline continuation.

## Hypothesis

For each field and repetition:

```text
delta_distinct_cells =
  distinct_cells(frontier_bursts) - distinct_cells(matched_baseline_bursts)
```

The null hypothesis is `E[delta_distinct_cells] <= 0`. The benchmark reports a
percentile bootstrap 95% confidence interval and sets `rejects_null` to `true`
only when the lower bound is strictly positive.

## Required Command

```bash
mix anti_agents.benchmark \
  --fields priv/benchmarks/fields_v1.json \
  --branching 8 \
  --repetitions 3 \
  --distance jaccard \
  --out tmp/anti_agents_benchmark.json
```

Use `--dry-run` first to inspect provider call count. Larger runs must pass
`--expensive`.

## Baseline Integrity

Baseline artifact responses are retried up to `--baseline-retry-budget`.
Permanent losses are reported as:

- `baseline_permanent_loss_count`
- `baseline_loss_adjustment`
- `adjusted_novel_frontier_cell_count`

If adjusted novelty is zero, the hypothesis test is forced not to reject the
null.

## Interpretation

A positive benchmark is evidence for this implementation and field set, not a
NoveltyBench reproduction. A null result is valid evidence and should be
documented rather than suppressed.
