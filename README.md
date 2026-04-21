# AntiAgents

<p align="center">
  <img src="assets/anti_agents.svg" alt="AntiAgents logo" width="200" />
</p>

<p align="center">
  <a href="https://opensource.org/licenses/MIT">
    <img alt="MIT License" src="https://img.shields.io/badge/license-MIT-0f172a?style=for-the-badge" />
  </a>
  <a href="https://github.com/nshkrdotcom/anti_agents">
    <img alt="GitHub" src="https://img.shields.io/badge/github-nshkrdotcom%2Fanti__agents-111827?style=for-the-badge&logo=github" />
  </a>
</p>

`anti_agents` is a frontier-engine prototype built around `codex_sdk`.
It keeps the surface small, makes the control flow explicit, and favors verbose
traceability over silent cleverness.

## Menu

- [Overview](#overview)
- [Quick start](#quick-start)
- [API](#api)
- [Design basis](#design-basis)
- [Reference](#reference)

## Overview

The library exposes a minimal set of frontier primitives:

- `AntiAgents.field/2` builds a normalized prompt field.
- `AntiAgents.burst/2` runs one model burst against that field.
- `AntiAgents.branch/3` fans out multiple bursts.
- `AntiAgents.compare/2` measures overlap against a baseline archive.
- `AntiAgents.frontier/2` returns a frontier report with exemplars and scores.

The current MVP uses real Codex SDK calls, threads `temperature` through the
runtime settings, and falls back to a deterministic synthesized mapping when a
model answer arrives without structured output. That keeps the prototype useful
even when the backend ignores the requested schema.

## Quick start

```bash
cd /home/home/p/g/North-Shore-AI/tinkerer/brainstorm/20260420/anti_agents
mix deps.get
mix test
```

## API

```elixir
field =
  AntiAgents.field("the memory of a color that doesn't exist",
    axes: [:ontology, :metaphor, :syntax, :affect],
    toward: ["machine pastoral", "sterile mysticism"],
    away_from: ["standard sci-fi"]
  )

burst = AntiAgents.burst(field, heat: [answer: 1.05], client: AntiAgents.CodexClient)

report = AntiAgents.frontier(field, branching: 12, baseline: [:plain, :paraphrase])

comparison = AntiAgents.compare(field, branching: 12, baseline: [:plain, :paraphrase])
```

Example output shape:

```elixir
%AntiAgents.FrontierReport{
  exemplars: [
    %AntiAgents.BurstResult{
      field: %AntiAgents.Field{},
      seed: "...",
      random_string: "...",
      mapping_trace: %{decisions: [...]},
      answer: "...",
      status: :accepted,
      rejection_reason: nil,
      score: %{},
      descriptor: %{
        semantic: "...",
        structural: %{},
        affect: :low,
        abstraction: :mid,
        seed_profile: %{}
      },
      coherence: 0.0,
      seed_coverage: 0.0
    }
  ],
  delta_frontier: 0.13,
  reachable_hits: [...],
  rejected_duplicates: [...],
  mapping_traces: [...],
  metrics: %{distinct: 1, coherence: 0.75, seed_coverage: 0.48, archive_coverage: 0.83}
}
```

## Design basis

This prototype is intentionally verbose and hypothesis-driven. It explores
whether entropy-first prompting and branch fanout can improve novelty without
collapsing into duplicate semantic cells.

The prompt structure is informed in part by String Seed of Thought (SSoT),
which argues for first generating random string entropy and then extracting a
final answer from that entropy stream:

- Misaki, Kou and Akiba, Takuya. *String Seed of Thought: Prompting LLMs for Distribution-Faithful and Diverse Generation.* arXiv:2510.21150. https://arxiv.org/abs/2510.21150

## Reference

- Source repository: https://github.com/nshkrdotcom/anti_agents
- License: MIT
- Paper reference: https://arxiv.org/abs/2510.21150
