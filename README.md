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
- [From SSoT to AntiAgents](#from-ssot-to-antiagents)
- [Research questions](#research-questions)
- [Live result](#live-result)
- [Mechanism](#mechanism)
- [Experimental trace](#experimental-trace)
- [Install](#install)
- [API](#api)
- [Output schema](#output-schema)
- [Scoring](#scoring)
- [CLI](#cli)
- [Anti-collapse policy](#anti-collapse-policy)
- [Limitations](#limitations)
- [Paper crosswalk](#paper-crosswalk)
- [Credits](#credits)
- [References](#references)
- [License](#license)

## Research context

This repository is a research prototype built from the Diversity-Aware Generation
(DAG) side of Misaki and Akiba's String Seed of Thought (SSoT) paper.[^1] The paper
studies two related failure modes of modern language models:

- **Probabilistic Instruction Following (PIF)**: the model should sample from a
  target distribution, but naive prompting often produces biased empirical
  frequencies.
- **Diversity-Aware Generation (DAG)**: the model should produce many valid,
  diverse responses without collapsing to familiar modes or losing quality.

SSoT addresses both by moving randomness into an explicit, inspectable
intermediate object. Instead of asking the model to "be random" directly, the
prompt asks the model to generate a random string and then manipulate that string
to select an action or construct a response. For DAG, the relevant instruction is
the paper's "generate a random string, and manipulate it to generate one diverse
response" form.

The paper reports three observations this package treats as engineering
constraints:

- SSoT improves open-ended diversity on NoveltyBench relative to plain
  baselines, paraphrase prompts, and temperature increases, while preserving
  utility.
- Each generation is independent, so SSoT is naturally batchable and parallel.
- The model's use of the string matters: strong runs use strategies such as
  rolling hashes, chunk-local decisions, and template filling; weak runs collapse
  to prefix-only or single-global-choice use.

`anti_agents` is an executable harness for studying that mechanism in live Codex
runs. It does not claim to reproduce the paper's NoveltyBench numbers. It asks a
narrower systems question: can SSoT-style coordinate generation, plus explicit
archive pressure, discover outputs outside what clean baseline prompting reaches
under an equal-budget live run?

## From SSoT to AntiAgents

The SSoT paper's core protocol is simple:

1. Generate an internal random string.
2. Manipulate that string through an explicit mapping strategy.
3. Produce the final action or answer from that mapping.

For open-ended generation, the paper's CoT analysis shows that useful diversity
often comes from decomposing the response into local creative choices. In the
fable example, chunks of the seed are assigned to setting, trait, conflict, and
moral. In the broader NoveltyBench analysis, creative tasks benefit when the
model constructs a template and samples local elements from the random string
rather than making one global theme choice.

`anti_agents` turns that observation into a frontier engine:

- A **field** is the conceptual region to explore.
- A **burst** is one SSoT-conditioned generation from that field.
- A **branch** is a parallel fanout of bursts.
- A **reachable archive** is built from ordinary baselines: plain prompting,
  paraphrase prompting, seed injection, and temperature sweeps.
- A **frontier archive** contains burst outputs that survive anti-collapse checks
  and do not land in cells already occupied by the reachable archive.

This is deliberately not an agent framework. It has no personas, tools, task
planner, autonomous loop, or conversation memory. The experimental object is not
"the best answer"; it is the set of outputs that occupy descriptor cells the
baseline archive did not occupy.

## Research questions

The live command is intended to make the following questions testable:

1. **Counterfactual novelty**: Given the same field and budget, do SSoT bursts
   occupy archive cells not reached by plain, paraphrase, or temperature baselines?
2. **Seed utilization**: Do accepted bursts use several chunks of the generated
   random string, or do they collapse to prefix-only / single-choice behavior?
3. **Trace honesty**: Can we inspect enough of the model's random string,
   mapping, baseline archive, accepted frontier, and rejection reasons to audit
   whether a positive result is real?
4. **Operational scalability**: Does the SSoT independence property translate
   into practical parallel execution through BEAM tasks and the Codex SDK?

The current harness has a concrete, falsifiable hypothesis:

> For a fixed field and equal attempted baseline/frontier budget, verified SSoT
> bursts should produce at least one descriptor cell not occupied by the reachable
> baseline archive, while preserving mean verified seed coverage above `0.5`.

The main reported statistic is `novel_frontier_cell_count`:

```text
reachable_cells = unique_descriptor_cells(accepted_baselines)
frontier_cells = unique_descriptor_cells(accepted_frontier)

novel_frontier_cell_count = |frontier_cells \ reachable_cells|
```

A positive value is not, by itself, a paper-level result. It is a live-run signal
that the current field, prompt contract, model, temperature, and archive
descriptors produced frontier cells beyond the reachable baseline set. The
current descriptor cell is deliberately simple: `{length, sentence_count, affect,
abstraction}`. Verified seed usage is measured and scored, but it is not part of
cell identity.

## Live result

The current hardening pass ran a small live Codex experiment with the following
command:

```bash
mix anti_agents.frontier "the memory of a color that does not exist" \
  --verbose \
  --heartbeat-ms 5000 \
  --branching 6 \
  --concurrency 4 \
  --temperature 1.1 \
  --model gpt-5.4-mini \
  --reasoning low \
  --baseline 'plain,paraphrase,temp:0.8|1.0|1.2|1.4' \
  --thinking-budget 1200 \
  --timeout-ms 240000 \
  --preview-chars 180 \
  --out tmp/anti_agents_live_frontier_verified_final3.json
```

The run attempted 6 baseline calls and 6 SSoT frontier bursts. Four baselines
entered the reachable archive; two baseline responses were rejected as prompt
artifacts. All six frontier bursts had valid host-verified mappings, five
survived reachable-cell filtering, and one was rejected because its descriptor
cell was already reachable.

```json
{
  "attempted_baseline_calls": 6,
  "accepted_reachable_baselines": 4,
  "attempted_frontier_bursts": 6,
  "accepted_frontier_exemplars": 5,
  "rejected_frontier_after_filter": 1,
  "reachable_cell_count": 4,
  "frontier_cell_count": 2,
  "novel_frontier_cell_count": 2,
  "mean_seed_coverage": 0.9714,
  "coverage_delta": 0.971,
  "invalid_mapping_count": 0,
  "schema_rejected_count": 0,
  "duplicate_random_string_count": 0,
  "meaningful_signal": true
}
```

Accepted frontier exemplars included:

```text
[coverage=1.0, cell={length: medium, sentence_count: single, affect: low, abstraction: mid}]
A color without a spectrum, remembered as a pressure behind the eyes: shy, impossible, and still faintly warm.

[coverage=0.857, cell={length: long, sentence_count: small, affect: low, abstraction: mid}]
I remember the impossible color as a held distance: not a shade, but a location the eye revisits after language has failed. It arrives as a soft contradiction, like warmth without light, and closes by leaving the absence intact.
```

Interpretation: this is useful evidence that the current SSoT contract can
produce auditable, non-reachable cells in a live Codex run. It is also modest
evidence. The field is narrow, the descriptor space is coarse, the default
distance backend is lexical, and this is not a NoveltyBench reproduction. The
result should be read as "the harness is experimentally usable and generated a
positive pilot signal," not as "SSoT frontier search is proved."

## Mechanism

Each **burst** follows the SSoT protocol:

1. A coordinate nonce is sampled host-side for run identity and traceability.
2. The model is instructed to internally generate its own random string.
3. The model returns a structured object with three fields:
   - `random_string` — the model-generated entropy string, not the host nonce
   - `mapping` — per-chunk decisions across exploration axes (`ontology`, `metaphor`, `syntax`, `affect`, `contradiction`, `closure`)
   - `answer` — the final generated text
4. Each mapping decision must include `axis`, `chunk`, `hash`, `choice`, and
   `value`. The host recomputes `hash = sum(bytes("#{chunk}:#{chunk_text}")) mod
   997` from the emitted `random_string`. Invalid hashes or chunk indexes are
   rejected.
5. The verified mapping is audited for **anti-collapse**: responses that reference
   only one chunk or cover fewer than `max(2, ⌈N/3⌉)` distinct chunks are rejected.
6. Accepted bursts are scored against a **reachable baseline archive** built from
   plain, paraphrase, seed-injection, and temperature-sweep completions of the same field.
7. Bursts whose descriptor cell matches any baseline cell are filtered into the
   reachable set; the remainder constitute the **frontier**.

Two details are intentionally stricter than a generic demo:

- Baseline calls use a clean non-SSoT contract. Except for the explicit
  `seed_injection` baseline, they do not receive the coordinate nonce, SSoT
  schema, or mapping instructions.
- Artifact guards reject prompt echoes, nested control JSON, malformed
  `random_string` / `mapping` payloads, code-fence output, and SDK/CLI tutorial
  responses before they can enter the reachable or frontier archives.
- Random-string guards reject nonce copying, very short strings, highly
  repetitive strings, and duplicate model-generated random strings within one
  frontier run.

## Experimental trace

The CLI writes a JSON trace designed for research inspection, not just debugging.
The trace includes:

- `synthesis`: the claim under test and anti-collapse checks.
- `run`: model, reasoning effort, temperature, branching, baseline methods, and
  coordinate configuration.
- `reachable_archive`: clean baseline responses and descriptors.
- `exemplars`: accepted frontier bursts, mappings, descriptors, scores, and seed
  coverage.
- `rejected_duplicates`: bursts rejected as reachable, duplicates, low coverage,
  or artifacts.
- `mapping_traces`: the full random-string-to-axis decision traces.
- `evidence`: summarized fields such as `meaningful_signal`,
  `reachable_baseline_count`, `accepted_frontier_count`,
  `novel_frontier_cell_count`, `coverage_delta`, `invalid_mapping_count`, and
  `mean_seed_coverage`.

With `--verbose`, the command also emits a human-readable run log:

- total LLM calls before the run starts,
- stage purpose for baseline and frontier phases,
- `LLM n/total` progress,
- in-flight heartbeat summaries,
- truncated input/output previews.

This logging is part of the research surface. It exists so a user can catch
experimental contamination, such as a baseline returning a CLI snippet or a burst
returning nested JSON as an answer, while the run is still interpretable.

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
  reachable_archive:   [%AntiAgents.BurstResult{}, ...],  # accepted baseline cells
  rejected_duplicates: [%AntiAgents.BurstResult{}, ...],  # duplicate/reachable/rejected burst attempts
  reachable_hits:      [%{descriptor: ..., reason: :reachable, score: ...}, ...],
  mapping_traces:      [%{"decisions" => [...]}, ...],     # audit trail for all frontier attempts
  frontier_cell_count: 2,
  reachable_cell_count: 4,
  novel_frontier_cell_count: 2,
  coverage_delta:      0.971,
  schema_rejected_count: 0,
  invalid_mapping_count: 0,
  duplicate_random_string_count: 0,
  metrics: %{
    distinct:         2,     # unique descriptor cells in accepted frontier
    coherence:        0.75,  # mean coherence of accepted bursts
    seed_coverage:    0.97,  # mean fraction of verified seed chunks referenced in mapping
    archive_coverage: 0.83   # accepted / attempted frontier bursts
  }
}
```

Each `%AntiAgents.BurstResult{}` carries:

| field | description |
|-------|-------------|
| `seed` | coordinate nonce used for this burst |
| `random_string` | entropy string generated by the model |
| `mapping_trace` | per-chunk axis decisions (full audit) |
| `mapping_verification` | host-side hash/chunk verification result |
| `answer` | final generated text |
| `status` | `:accepted` \| `:rejected` \| `:parse_error` \| `:provider_error` |
| `score` | `%{baseline_distance, frontier_distance, seed_coverage, coherence, overall}` |
| `descriptor` | `%{semantic, structural, affect, abstraction, seed_profile, cell}` |
| `coherence` | float in [0, 1] |
| `seed_coverage` | fraction of emitted random-string chunks verified as used in mapping |

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

Descriptor cells are 4-dimensional buckets `{length, sentence_count, affect,
abstraction}` used for archive membership testing. Seed coverage is not included
in the cell. This is important: otherwise SSoT outputs can look novel merely
because baselines have no mapping trace.

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
`novel_frontier_cell_count`, `mean_seed_coverage`), the clean `reachable_archive`,
and per-exemplar mapping audit trails.

## Anti-collapse policy

Without explicit checks, SSoT-style prompts collapse: the model selects a single
global theme from the first seed chunk and ignores the rest. `anti_agents` rejects
any burst where:

- the emitted `random_string` is copied from the host coordinate nonce,
- the emitted `random_string` is too short or highly repetitive,
- the emitted `random_string` duplicates another frontier burst in the same run,
- any decision references an invalid chunk or supplies a wrong hash,
- only one distinct chunk index appears across all verified mapping decisions, or
- fewer than `max(2, ⌈chunk_count / 3⌉)` distinct chunks are verified.

When the backend returns unstructured plain text from a burst call, the output is
preserved in the trace as `:parse_error`; it is not promoted into a frontier
exemplar with a synthetic mapping.

## Limitations

This package should be read as a live research harness, not as a completed
benchmark implementation.

**Descriptor quality.** The current archive descriptors are deliberately simple:
semantic fingerprint, structural buckets, affect band, abstraction level, and
seed-usage profile. Archive cell identity currently uses only structural buckets,
affect band, and text-derived abstraction level. These descriptors are sufficient
for inspecting whether the pipeline works, but they are not a substitute for
NoveltyBench's full evaluation protocol or a learned behavior descriptor.

**Distance quality.** The default similarity function uses lexical Jaccard
distance. This is transparent and cheap, but it misses semantic equivalence and
over-penalizes paraphrases. The intended next step is an embedding or
LLM-as-judge distance backend.

**Model dependence.** The paper emphasizes that SSoT depends on reasoning
capability. Smaller or weaker models may fail to generate useful random strings,
execute local mappings, or avoid prefix-only strategies. This package exposes
`seed_coverage` and rejection reasons so those failures are visible.

**Prompt/schema fragility.** Live LLMs sometimes return prompt echoes, malformed
nested JSON, or SDK/tutorial text. `anti_agents` rejects these artifacts, but the
need for such guards is itself an experimental result: traceability is mandatory
when studying diversity.

**Semantic vs latent exploration.** The current implementation is an inference-time
semantic exploration backend. It explores the model's reachable output manifold
through controlled entropy and archive pressure. It does not yet implement true
activation-space, LoRA, SVF, or weight-space steering.

**Single-answer tasks.** As in the SSoT paper, this method is intended for tasks
with multiple acceptable outputs or probabilistic requirements. It is not meant
for factual lookup, proof obligations, or tasks with one correct answer.

## Paper crosswalk

Key mappings from the paper to this package:

| Paper concept | Where it appears here |
|---------------|------------------------|
| PIF and DAG distinction | README frames `anti_agents` as a DAG/frontier harness, not a PIF sampler |
| SSoT two-stage instruction | `AntiAgents.Prompt.burst_prompt/2` asks for `random_string`, `mapping`, and `answer` |
| Full parallelizability | `AntiAgents.branch/3` and baseline archive construction use `Task.async_stream` |
| NoveltyBench comparison against baseline, paraphrase, and temperature | `AntiAgents.frontier/2` builds a reachable archive from `:plain`, `:paraphrase`, `:seed_injection`, and `{:temperature, [...]}` |
| DAG strategy: templates plus local random selection | `mapping.decisions` requires chunk-local axis decisions over ontology, metaphor, syntax, affect, contradiction, and closure, with host-verifiable `hash` and `choice` fields |
| Simple SSoT prompt components | The prompt contract preserves explicit string generation, manipulation, and final answer extraction |
| External randomness/tool-call limitations | Host nonces are used only for trace identity; the model must emit its own `random_string`; no model-visible tool calls are required |
| Bias propagation from lazy prefix use | Anti-collapse rejects prefix-only mappings, low verified coverage, nonce copying, repetitive strings, and duplicate model random strings |
| Reasoning-capability dependence | README and trace surface `reasoning_effort`, `thinking_budget`, `seed_coverage`, and rejection reasons |

The main extension beyond the paper is **counterfactual frontier accounting**:
SSoT outputs are not treated as diverse merely because they differ from each
other. They are compared against a clean reachable archive, and only cells not
occupied by that archive count as frontier expansion.

## Credits

The concept of an anti-agents SDK — no entities, high temperature, explicitly a
latent space exploration tool, optimised for coverage over task completion — was
proposed by [@threepointone](https://x.com/threepointone/status/2046373376990605423)
on X (April 20, 2026).

## References

[^1]: Misaki, Kou, and Akiba, Takuya. "String Seed of Thought: Prompting LLMs for Distribution-Faithful and Diverse Generation." arXiv:2510.21150, 2025. https://arxiv.org/abs/2510.21150

## License

[MIT](LICENSE) — Copyright © 2026 nshkrdotcom
