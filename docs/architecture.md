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
- Distance layer: pluggable similarity backend behavior.
- Statistics layer: distinct-cell counts and bootstrap confidence
  intervals.
- Trace writer: JSON evidence report.
- Frontier Mix task: single-field CLI.
- Benchmark Mix task: multi-field matched-budget benchmark CLI.

## Boundary

The current system explores the reachable output manifold through prompt-time
coordinates and archive pressure. It does not implement activation-space,
adapter-space, or weight-space steering.
