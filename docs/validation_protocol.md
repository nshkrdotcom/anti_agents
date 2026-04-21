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
per-field mean-delta percentile bootstrap 95% confidence interval and a
one-sided sign test over field/repetition deltas. It sets `rejects_null` to
`true` only when the mean-delta lower bound is strictly positive and
`sign_test_p < 0.05`.

## Required Command

```bash
mix anti_agents.benchmark \
  --profile priv/profiles/evidence.json \
  --fields priv/benchmarks/fields_v1.json \
  --branching 8 \
  --repetitions 3 \
  --distance embedding \
  --embedding-model gemini-embedding-001 \
  --embedding-auth gemini \
  --embedding-task-type clustering \
  --embedding-dimensions 768 \
  --frontier-temperature-sweep '1.0|1.1|1.2' \
  --expensive \
  --out tmp/anti_agents_benchmark.json
```

Use `--dry-run` first to inspect provider call count. Larger runs must pass
`--expensive`.

## Model And Reasoning Policy

Diagnostic runs may use `gpt-5.4-mini` with `--reasoning low`. This is the
cheap path for parser tests, progress logging, trace shape, Gemini embedding
plumbing, and short smoke runs. Diagnostic output is not evidence.

Evidence runs must use `priv/profiles/evidence.json` without model overrides.
The current evidence profile uses:

```json
{
  "model": "gpt-5.4",
  "reasoning_effort": "high",
  "thinking_budget": 4000,
  "distance": "embedding",
  "embedding_model": "gemini-embedding-001",
  "embedding_auth": "gemini",
  "embedding_task_type": "clustering",
  "embedding_dimensions": 768
}
```

This matters because SSoT is part of the measured instrument. A model with
weaker reasoning can fail by emitting poor random strings, ignoring local
chunks, producing invalid hash mappings, or collapsing to prefix-only
strategies. Changing `model`, `reasoning_effort`, or `thinking_budget` creates
a different experiment and must not be mixed with evidence-profile results.

The evidence profile configures `AntiAgents.Embedding.GeminiClient`, which uses
`gemini_ex` batch embeddings. A live evidence run requires `GEMINI_API_KEY` or
Vertex credentials supported by `gemini_ex`.

Before interpreting any live benchmark result, run:

```bash
mix anti_agents.calibrate --stubbed
```

This is the QC positive control. It must report
`evidence.hypothesis_test.rejects_null: true`; otherwise the benchmark
instrument is considered miscalibrated.

## Diagnostic Runs

Runs with `--branching < 4` are diagnostic-only. The benchmark task refuses
them unless `--diagnostic` is passed, and diagnostic output is marked
`mode: "benchmark_diagnostic"`. These runs are useful for checking plumbing,
trace shape, progress logging, and provider behaviour. They are not evidence.

Any cited benchmark number requires:

- `branching >= 6`
- `repetitions >= 3`
- `--profile priv/profiles/evidence.json`
- no model, reasoning, or thinking-budget overrides from the evidence profile
- `--distance embedding` with integer `semantic_cluster` descriptor values
- Gemini embedding metadata recorded in `run.embedding`
- explicit frontier temperature points recorded as `frontier_temperature_points`
- a non-diagnostic output mode
- a calibration run that passed on the same calendar day

## Descriptor Ablation

After producing an evidence-profile trace, run descriptor ablation offline:

```bash
mix anti_agents.ablate \
  --fields priv/benchmarks/fields_v1.json \
  --branching 8 \
  --repetitions 3 \
  --reference-trace tmp/anti_agents_benchmark.json \
  --modes jaccard,embedding \
  --out tmp/anti_agents_ablation.json
```

The ablation task must report `provider_calls: 0`. It reuses the same recorded
frontier and matched-baseline bursts, so the only changed variable is the
descriptor view. The acceptance bar for descriptor robustness is
`summary.directional_agreement >= 0.7`. If directional agreement is below 0.7,
the evidence claim must be scoped to the descriptor backend that produced it
rather than presented as backend-independent.

## Baseline Integrity

Baseline artifact responses are retried up to `--baseline-retry-budget`.
Permanent losses are reported as:

- `baseline_permanent_loss_count`
- `baseline_loss_adjustment`
- `adjusted_novel_frontier_cell_count`
- `matched_baseline_permanent_loss_count`
- `matched_baseline_loss_adjustment`
- `adjusted_matched_baseline_cell_count`

If adjusted novelty is zero, the hypothesis test is forced not to reject the
null.

Frontier anti-collapse and matched-baseline artefact rejection are intentionally
different checks. Frontier bursts must prove they used the SSoT mapping;
matched baselines cannot do that because they have no mapping trace. Both arms
must still expose retries and permanent losses separately.

## Interpretation

A positive benchmark is evidence for this implementation and field set, not a
NoveltyBench reproduction. A null result is valid evidence and should be
documented rather than suppressed.
