# Architecture

AntiAgents is a semantic-space frontier-search harness built around immutable
value objects and bounded provider calls.

## Flow

```text
Field
  -> baseline prompts
  -> reachable archive
  -> SSoT bursts
  -> archive feedback rounds
  -> matched baseline continuation
  -> scoring and hypothesis test
  -> trace JSON
```

## Components

- Field value object: normalized field prompt, axes, and steering text.
- Prompt builder: SSoT burst contract and clean baseline prompt contract.
- Burst runner: parallel burst execution through `Task.async_stream`.
- Frontier assembler: reachable archive construction, frontier filtering,
  matched-budget comparison, archive-feedback rounds, and report assembly.
- Scoring layer: mapping verification, descriptor cells, coherence,
  scoring weights, and fallback lexical similarity.
- Distance layer: pluggable similarity backend behavior; the production
  embedding adapter is `AntiAgents.Embedding.GeminiClient`, backed by
  `gemini_ex` batch embeddings.
- Statistics layer: distinct-cell counts and bootstrap confidence
  intervals.
- Trace writer: JSON evidence report.
- Frontier Mix task: single-field CLI.
- Benchmark Mix task: multi-field matched-budget benchmark CLI.

## Statistical Pipeline

```text
burst
  -> descriptor cell
  -> per-run frontier cell count
  -> per-run matched-baseline cell count
  -> per-field delta
  -> bootstrap CI over mean delta
  -> one-sided sign test
  -> aggregate rejects_null decision
```

The pooled distinct-cell statistic is retained only as a diagnostic field. The
headline benchmark decision uses per-field/repetition deltas so cells from
different prompts do not collide in one shared surface bucket vocabulary.

Descriptor saturation is tracked separately through `empirical_cell_space`,
`saturation`, and `cell_saturation_warning`. If too many runs saturate the
available descriptor space, the benchmark-level `calibration_status` is set to
`descriptor_saturated`.

When `distance: :embedding` is used through the CLI, reachable baseline answers
are embedded with Gemini, fitted into centroids, and then reused to assign
integer `semantic_cluster` values to baseline, frontier, and matched-baseline
outputs. If the embedding provider is missing or fails, the descriptor status
degrades explicitly and `semantic_cluster` remains `:unknown`.

## Boundary

The current system explores the reachable output manifold through prompt-time
coordinates and archive pressure. It does not implement activation-space,
adapter-space, or weight-space steering.
