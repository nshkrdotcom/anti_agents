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

## Modules

- `AntiAgents.Field`: normalized field prompt, axes, and steering text.
- `AntiAgents.Prompt`: SSoT burst contract and clean baseline prompt contract.
- `AntiAgents.Bursts`: parallel burst execution through `Task.async_stream`.
- `AntiAgents.Frontier`: reachable archive construction, frontier filtering,
  matched-budget comparison, archive-feedback rounds, and report assembly.
- `AntiAgents.Scoring`: mapping verification, descriptor cells, coherence,
  scoring weights, and fallback lexical similarity.
- `AntiAgents.Distance`: pluggable similarity backend behavior.
- `AntiAgents.Statistics`: distinct-cell counts and bootstrap confidence
  intervals.
- `AntiAgents.Trace`: JSON evidence report.
- `Mix.Tasks.AntiAgents.Frontier`: single-field CLI.
- `Mix.Tasks.AntiAgents.Benchmark`: multi-field matched-budget benchmark CLI.

## Boundary

The current system explores the reachable output manifold through prompt-time
coordinates and archive pressure. It does not implement activation-space,
adapter-space, or weight-space steering.
