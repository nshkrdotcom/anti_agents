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

An Elixir prototype for entropy-first latent space exploration with LLMs. No agent
abstractions — only primitives for injecting structured randomness into generation,
fanning out parallel bursts, and measuring novelty against a reachable baseline archive.

## Contents

- [Research context](#research-context)
- [Mechanism](#mechanism)
- [Install](#install)
- [API](#api)
- [Output schema](#output-schema)
- [Scoring](#scoring)
- [CLI](#cli)
- [Anti-collapse policy](#anti-collapse-policy)
- [Credits](#credits)
- [License](#license)

## Research context

This prototype operationalizes two ideas simultaneously.

**String Seed of Thought (SSoT)** — Misaki & Akiba (arXiv:2510.21150) show that
prepending a randomly sampled string before answer generation shifts the model's
output distribution in a controllable, reproducible way. The random string acts as
a coordinate in latent space: different seeds yield semantically distant outputs
even under identical prompts, improving both diversity and distributional coverage.

**Anti-Agents** — the motivating conjecture (see [Credits](#credits)) is that
productive latent-space exploration requires the inverse of agentic machinery: no
task decomposition, no memory, no entities — high-temperature generation with
explicit coordinate control, optimised for coverage of the reachable output manifold
rather than task completion.

`anti_agents` tests whether combining SSoT-style seed injection with archive-based
novelty filtering can expand the reachable frontier beyond what baseline sampling
achieves, and whether that expansion is measurable and reproducible.

## Mechanism

Each **burst** follows the SSoT protocol:

1. A random alphanumeric seed is sampled (default 32 chars).
2. The seed is passed to the model alongside a structured prompt requesting a JSON object with three fields:
   - `random_string` — a freshly generated entropy string (not the coordinate nonce)
   - `mapping` — per-chunk decisions across exploration axes (`ontology`, `metaphor`, `syntax`, `affect`, `contradiction`, `closure`)
   - `answer` — the final generated text
3. The mapping is audited for **anti-collapse**: responses that reference only the
   first chunk (prefix collapse) or cover fewer than ⌈N/3⌉ distinct chunks are rejected.
4. Accepted bursts are scored against a **reachable baseline archive** built from
   plain, paraphrase, seed-injection, and temperature-sweep completions of the same field.
5. Bursts whose descriptor cell matches any baseline cell are filtered into the
   reachable set; the remainder constitute the **frontier**.

`delta_frontier` = |novel frontier cells| − |reachable baseline cells|

## Install

Requires Elixir `~> 1.18` and a configured `codex_sdk ~> 0.16` environment.

```elixir
# mix.exs
{:anti_agents, github: "nshkrdotcom/anti_agents"}
```

```bash
mix deps.get
mix test
```

## API

```elixir
# Define an exploration region
field = AntiAgents.field("the memory of a color that doesn't exist",
  axes: [:ontology, :metaphor, :syntax, :affect],
  toward: ["machine pastoral", "sterile mysticism"],
  away_from: ["standard sci-fi"]
)

# Single burst — one entropy-injected generation
burst = AntiAgents.burst(field, heat: [answer: 1.05])

# Parallel fanout — n bursts from independent seeds
bursts = AntiAgents.branch(field, 12, heat: [answer: 1.05])

# Full frontier run — fanout + baseline archive + novelty filtering + scoring
report = AntiAgents.frontier(field,
  branching: 12,
  baseline: [:plain, :paraphrase, {:temperature, [0.8, 1.0, 1.2]}, :seed_injection]
)

# Comparison only — returns raw archives without exemplar scoring
comparison = AntiAgents.compare(field, branching: 12, baseline: [:plain, :paraphrase])
```

**`AntiAgents.field/2` options**

| key | type | description |
|-----|------|-------------|
| `axes` | `[atom]` | exploration dimensions used in per-chunk mapping |
| `toward` | `[String.t]` | positive steering targets |
| `away_from` | `[String.t]` | negative steering targets |

**`burst/2` / `branch/3` / `frontier/2` options**

| key | default | description |
|-----|---------|-------------|
| `heat` | `[seed: 1.3, assembly: 1.15, answer: 1.05]` | per-phase temperature |
| `branching` | `8` | burst count for `branch` and `frontier` |
| `baseline` | `[:plain, :paraphrase, {:temperature, [0.8, 1.0, 1.2]}, :seed_injection]` | reachable archive construction methods |
| `coordinate` | `[length: 32, chunk: 5]` | seed length and chunk size |
| `thinking_budget` | `1200` | `max_tokens` forwarded to the model |
| `model` | `"gpt-5.4-mini"` | Codex model string |
| `reasoning_effort` | `:low` | reasoning effort forwarded to Codex |
| `client` | `AntiAgents.CodexClient` | any module implementing `AntiAgents.Client` |

## Output schema

`AntiAgents.frontier/2` returns `%AntiAgents.FrontierReport{}`:

```elixir
%AntiAgents.FrontierReport{
  field:               %AntiAgents.Field{},
  exemplars:           [%AntiAgents.BurstResult{}, ...],  # accepted frontier bursts
  rejected_duplicates: [%AntiAgents.BurstResult{}, ...],  # near-duplicates or reachable hits
  reachable_hits:      [%{descriptor: ..., reason: :reachable, score: ...}, ...],
  mapping_traces:      [%{"decisions" => [...]}, ...],     # full audit trail
  delta_frontier:      0.13,                               # novel cells beyond baseline
  metrics: %{
    distinct:         7,     # unique descriptor cells in frontier
    coherence:        0.75,  # mean coherence of accepted bursts
    seed_coverage:    0.48,  # mean fraction of seed chunks referenced in mapping
    archive_coverage: 0.83   # accepted / total frontier bursts
  }
}
```

Each `%AntiAgents.BurstResult{}` carries:

| field | description |
|-------|-------------|
| `seed` | coordinate nonce used for this burst |
| `random_string` | entropy string generated by the model |
| `mapping_trace` | per-chunk axis decisions (full audit) |
| `answer` | final generated text |
| `status` | `:accepted` \| `:rejected` \| `:parse_error` \| `:provider_error` |
| `score` | `%{baseline_distance, frontier_distance, seed_coverage, coherence, overall}` |
| `descriptor` | `%{semantic, structural, affect, abstraction, seed_profile, cell}` |
| `coherence` | float in [0, 1] |
| `seed_coverage` | fraction of seed chunks referenced in mapping |

## Scoring

The composite score weights novelty over coherence:

```
overall = 0.50 × baseline_distance
        + 0.25 × frontier_distance
        + 0.15 × seed_coverage
        + 0.10 × coherence
```

`baseline_distance` and `frontier_distance` are `1 − max_jaccard_similarity`
against the respective archive. Near-duplicate detection threshold: 0.91 Jaccard.

Descriptor cells are 5-dimensional buckets `{length, sentence_count, affect,
abstraction, coverage}` used for archive membership testing. Two bursts occupying
the same cell are treated as semantically equivalent for frontier accounting.

## CLI

```bash
mix anti_agents.frontier "the memory of a color that doesn't exist" \
  --verbose \
  --heartbeat-ms 5000 \
  --branching 12 \
  --temperature 1.18 \
  --model gpt-5.4-mini \
  --reasoning low \
  --baseline 'plain,paraphrase,temp:0.8|1.0' \
  --toward "machine pastoral" \
  --away-from "standard sci-fi" \
  --preview-chars 180 \
  --out trace.json
```

Add `--dry-run` to print the resolved run configuration without calling the model.
Use `--verbose` for human-readable progress: the command prints the total LLM call
plan, the current stage, `LLM n/total`, why each baseline/frontier call exists,
heartbeats with in-flight work, and truncated input/output previews. Use
`--preview-chars N` to tune preview length.

The `--out` path receives a structured JSON trace (`AntiAgents.Trace`) that includes
the synthesis claim under test, run parameters, evidence summary (`meaningful_signal`,
`delta_frontier`, `mean_seed_coverage`), the clean `reachable_archive`, and
per-exemplar mapping audit trails.

## Anti-collapse policy

Without explicit checks, SSoT-style prompts collapse: the model selects a single
global theme from the first seed chunk and ignores the rest. `anti_agents` rejects
any burst where:

- only one distinct chunk index appears across all mapping decisions (prefix collapse), or
- fewer than `max(2, ⌈chunk_count / 3⌉)` distinct chunks are referenced.

When the backend returns unstructured plain text (no JSON), a synthetic mapping is
deterministically derived from the answer text and the seed so that scoring and
audit remain consistent. The `rejection_reason` field records this fallback explicitly.


## Credits

The concept of an anti-agents SDK — no entities, high temperature, explicitly a
latent space exploration tool, optimised for coverage over task completion — was
proposed by [@threepointone](https://x.com/threepointone/status/2046373376990605423)
on X (April 20, 2026).

The entropy injection mechanism is grounded in:

> Misaki, Kou and Akiba, Takuya. **String Seed of Thought: Prompting LLMs for
> Distribution-Faithful and Diverse Generation.** arXiv:2510.21150 (2025).
> https://arxiv.org/abs/2510.21150

## License

[MIT](LICENSE) — Copyright © 2026 nshkrdotcom
