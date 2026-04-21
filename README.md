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

An Elixir research prototype for entropy-first exploration of the reachable output
manifold of large language models. The package exposes no agent, planner, or
conversational-memory abstractions; it provides only primitives for injecting
structured randomness into generation, fanning out parallel bursts under the
BEAM concurrency model, and measuring novelty against a reachable baseline
archive.

## Contents

- [Research context](#research-context)
- [From SSoT to AntiAgents](#from-ssot-to-antiagents)
- [Research questions](#research-questions)
- [Live result](#live-result)
- [Mechanism](#mechanism)
- [Experimental trace](#experimental-trace)
- [Installation](#installation)
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

This repository is a research prototype derived from the Diversity-Aware
Generation (DAG) component of Misaki and Akiba's *String Seed of Thought*
(SSoT) paper.[^1] That work characterises two related failure modes of
contemporary language models:

- **Probabilistic Instruction Following (PIF)** — the model is required to
  sample from a specified target distribution, yet naive prompting yields
  systematically biased empirical frequencies.
- **Diversity-Aware Generation (DAG)** — the model is required to produce
  many valid, diverse responses without collapsing to familiar modes or
  sacrificing utility.

SSoT addresses both regimes by externalising randomness into an explicit,
inspectable intermediate object. Rather than instructing the model to "be
random" directly, the prompt directs the model to generate a random string and
subsequently to manipulate that string in order to select an action or to
construct a response. For DAG, the relevant instruction is the paper's
"generate a random string, and manipulate it to generate one diverse response"
formulation.

The paper reports three empirical observations that this package adopts as
engineering constraints:

- SSoT improves open-ended diversity on NoveltyBench relative to plain
  baselines, paraphrase prompts, and temperature increases, without degrading
  task utility.
- Each generation is independent, so the method is naturally batchable and
  admits straightforward parallel execution.
- The model's use of the generated string is decisive: strong runs exhibit
  strategies such as rolling hashes, chunk-local decisions, and template
  filling, whereas weak runs collapse to prefix-only or single-global-choice
  behaviour.

`anti_agents` is an executable harness for studying that mechanism in live
Codex runs. It does not aim to reproduce the paper's NoveltyBench results. It
instead addresses a narrower systems-level question: under an equal-budget
live run, does SSoT-style coordinate generation combined with explicit archive
pressure discover outputs lying outside the region reachable by clean baseline
prompting?

## From SSoT to AntiAgents

The core SSoT protocol comprises three steps:

1. Generate an internal random string.
2. Manipulate that string through an explicit mapping strategy.
3. Derive the final action or answer from that mapping.

For open-ended generation, the paper's chain-of-thought analysis establishes
that useful diversity typically arises when the response is decomposed into
local creative choices. In the fable example, chunks of the seed are assigned
to setting, trait, conflict, and moral; more broadly, NoveltyBench performance
improves when the model constructs a template and samples local elements from
the random string rather than committing to a single global theme.

`anti_agents` operationalises this observation as a frontier-search engine
organised around the following value objects:

- A **field** is the conceptual region to be explored.
- A **burst** is a single SSoT-conditioned generation drawn from that field.
- A **branch** is a parallel fanout of bursts.
- A **reachable archive** is constructed from standard baselines: plain
  prompting, paraphrase prompting, seed injection, and temperature sweeps.
- A **frontier archive** contains burst outputs that pass anti-collapse checks
  and occupy descriptor cells not already occupied by the reachable archive.

The library is deliberately not an agent framework. It defines no personas,
tools, task planner, autonomous loop, or conversational memory. The
experimental object of interest is not "the best answer" but the subset of
outputs occupying descriptor cells inaccessible to the baseline archive.

## Research questions

The live-run command is designed to make the following questions empirically
testable:

1. **Counterfactual novelty.** Under a fixed field and equal budget, do SSoT
   bursts occupy archive cells that are not reached by plain, paraphrase, or
   temperature-swept baselines?
2. **Seed utilisation.** Do accepted bursts genuinely exploit multiple chunks
   of the generated random string, or do they collapse to prefix-only or
   single-choice behaviour?
3. **Trace auditability.** Is the run trace — comprising the model's random
   string, its mapping, the baseline archive, the accepted frontier, and all
   rejection reasons — sufficient to assess whether a positive result is
   genuine?
4. **Operational scalability.** Does the independence property established by
   SSoT translate into practical parallel execution via BEAM tasks and the
   Codex SDK?

The harness adopts a concrete and falsifiable hypothesis:

> Across a fixed field set, SSoT frontier bursts should produce more distinct
> descriptor cells than an equal-size matched-baseline continuation. The null
> hypothesis is `E[delta_distinct_cells] <= 0`; the benchmark rejects the null
> only when the bootstrap-resampled 95% lower bound is strictly positive.

The single-run accounting still reports `novel_frontier_cell_count`, but the
benchmark statistic is stricter:

```text
reachable_cells = unique_descriptor_cells(accepted_baselines)
frontier_cells = unique_descriptor_cells(accepted_frontier)
matched_cells = unique_descriptor_cells(matched_baseline_continuation)

novel_frontier_cell_count = |frontier_cells \ reachable_cells|
delta_distinct_cells = |frontier_cells| - |matched_cells|
```

A positive `novel_frontier_cell_count` is a pilot signal. A positive benchmark
claim requires `evidence.hypothesis_test.rejects_null == true` after baseline
loss adjustment.

## Live result

### Pilot

The most recent hardening pass executed a small live Codex experiment using
the following command:

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

The run issued six baseline calls and six SSoT frontier bursts. Four
baselines entered the reachable archive, while two baseline responses were
discarded as prompt artefacts. All six frontier bursts produced mappings that
passed host-side verification; five survived the reachable-cell filter, and
one was rejected because its descriptor cell was already reachable.

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
  "duplicate_random_string_count": 0
}
```

Accepted frontier exemplars included:

```text
[coverage=1.0, cell={length: medium, sentence_count: single, affect: low, abstraction: mid}]
A color without a spectrum, remembered as a pressure behind the eyes: shy, impossible, and still faintly warm.

[coverage=0.857, cell={length: long, sentence_count: small, affect: low, abstraction: mid}]
I remember the impossible color as a held distance: not a shade, but a location the eye revisits after language has failed. It arrives as a soft contradiction, like warmth without light, and closes by leaving the absence intact.
```

Interpretation. The outcome provides useful evidence that the present SSoT
contract can produce auditable, non-reachable cells in a live Codex run. The
evidence is, however, modest in scope: the field is narrow, the descriptor
space is coarse, the default distance backend is lexical, and the experiment
is not a NoveltyBench reproduction. The result should be read as demonstrating
that the harness is experimentally usable and has generated a positive pilot
signal, rather than as establishing frontier search under SSoT.

### Benchmark

The benchmark harness is now the primary evidence path:

```bash
mix anti_agents.benchmark \
  --fields priv/benchmarks/fields_v1.json \
  --branching 8 \
  --repetitions 3 \
  --distance jaccard \
  --out tmp/anti_agents_benchmark.json
```

Run the dry plan first:

```bash
mix anti_agents.benchmark --fields priv/benchmarks/fields_v1.json --dry-run
```

The default 12-field, 3-repetition plan reports:

```json
{
  "field_count": 12,
  "repetitions": 3,
  "baseline_calls_per_run": 6,
  "frontier_bursts_per_run": 8,
  "matched_baseline_calls_per_run": 8,
  "planned_llm_calls": 792,
  "mode": "benchmark_dry_run"
}
```

The live benchmark report writes `evidence.hypothesis_test.rejects_null` as a
boolean. A `false` value is a valid empirical result and should be reported, not
suppressed.

For live benchmark runs, use verbose mode when collecting evidence:

```bash
mix anti_agents.benchmark \
  --fields priv/benchmarks/fields_v1.json \
  --branching 1 \
  --repetitions 1 \
  --baseline plain \
  --model gpt-5.4-mini \
  --reasoning low \
  --temperature 1.05 \
  --bootstrap-resamples 200 \
  --timeout-ms 240000 \
  --verbose \
  --heartbeat-ms 5000 \
  --preview-chars 180 \
  --out tmp/anti_agents_benchmark_smoke.json
```

Verbose benchmark logs intentionally report both global and local progress:

```text
Benchmark plan: 12 fields × 1 repetitions = 12 runs, 36 planned LLM calls, 3 calls/run.
Benchmark run 6/12 | field 6/12 city-forget | repetition 1/1 | completed_llm=15/36 | this_run_calls=3
benchmark run 6/12 field=city-forget | Plan: 3 LLM calls = 1 baseline + 1 frontier bursts + 1 matched-baseline continuation, concurrency=24.
benchmark run 6/12 field=city-forget | LLM 16/36 | local LLM 1/3 baseline 1/1 plain started
Still running after 5.0s | stage=benchmark run 6/12 field 6/12 city-forget; LLM 15/36; baseline 0/2; bursts 0/1 | inflight=benchmark run 6/12 field=city-forget LLM 16/36 baseline 1/1 5.0s
```

The local `1/3` counter describes the current field-level run; the global
`16/36` counter describes the whole benchmark. This distinction matters because
the benchmark repeats the same three-stage frontier comparison across every
field and repetition.

## Mechanism

Each **burst** conforms to the following SSoT protocol:

1. A coordinate nonce is sampled host-side to provide run identity and
   traceability.
2. The model is instructed to internally generate its own random string.
3. The model returns a structured object with three fields:
   - `random_string` — the model-generated entropy string, distinct from the host nonce;
   - `mapping` — per-chunk decisions across the exploration axes (`ontology`, `metaphor`, `syntax`, `affect`, `contradiction`, `closure`);
   - `answer` — the final generated text.
4. Each mapping decision must carry `axis`, `chunk`, `hash`, `choice`, and
   `value`. The host recomputes `hash = sum(bytes("#{chunk}:#{chunk_text}")) mod
   997` from the emitted `random_string`; decisions with invalid hashes or
   out-of-range chunk indices are rejected.
5. The verified mapping is audited for **anti-collapse**: responses that
   reference only a single chunk, or cover fewer than `max(2, ⌈N/3⌉)` distinct
   chunks, are rejected.
6. Accepted bursts are scored against a **reachable baseline archive**
   constructed from plain, paraphrase, seed-injection, and temperature-sweep
   completions of the same field.
7. Bursts whose descriptor cell coincides with any baseline cell are routed
   into the reachable set; the remainder constitute the **frontier**.

Several design choices are intentionally more stringent than is typical in
demonstration code:

- Baseline calls operate under a clean, non-SSoT contract. With the exception
  of the explicit `seed_injection` baseline, they are not supplied the
  coordinate nonce, the SSoT schema, or any mapping instructions.
- Artefact guards reject prompt echoes, nested control JSON, malformed
  `random_string` or `mapping` payloads, code-fenced output, and SDK/CLI
  tutorial responses before such content can enter either archive.
- Baseline artefacts are retried up to `--baseline-retry-budget`; permanent
  losses are debited through `adjusted_novel_frontier_cell_count`.
- Random-string guards reject nonce copying, excessively short strings,
  highly repetitive strings, and duplicate model-generated random strings
  observed within a single frontier run.
- `--rounds N` enables archive-feedback rounds. Later frontier rounds receive a
  short steering delta derived only from accepted archive occupancy; if a round
  produces no accepted bursts, the run records `stagnation_at_round`.
- `--matched-budget` adds an equal-size baseline continuation after frontier
  generation. The benchmark compares distinct cells from this continuation
  against distinct frontier cells with a bootstrap confidence interval.

## Experimental trace

The CLI emits a JSON trace intended for research inspection rather than mere
debugging. The trace contains:

- `synthesis` — the claim under test together with the configured
  anti-collapse checks;
- `run` — model, reasoning effort, temperature, branching, baseline methods,
  and coordinate configuration;
- `reachable_archive` — clean baseline responses and their descriptors;
- `exemplars` — accepted frontier bursts with mappings, descriptors, scores,
  and seed-coverage values;
- `rejected_duplicates` — bursts rejected as reachable, duplicate, low in
  coverage, or artefactual;
- `mapping_traces` — the complete random-string-to-axis decision traces;
- `matched_baseline_archive` — equal-size baseline continuation used for the
  benchmark statistic;
- `evidence` — summary fields including `hypothesis_test`,
  `reachable_baseline_count`, `accepted_frontier_count`,
  `novel_frontier_cell_count`, `adjusted_novel_frontier_cell_count`,
  `baseline_loss_adjustment`, `coverage_delta`, `invalid_mapping_count`, and
  `mean_seed_coverage`.

Invoking the command with `--verbose` additionally emits a human-readable run
log that reports:

- the total number of LLM calls planned before the run begins;
- the stage purpose of each baseline and frontier phase;
- `LLM n/total` progress;
- in-flight heartbeat summaries;
- truncated input and output previews.

This logging forms part of the research surface. It is provided so that
experimental contamination — for example, a baseline that returns a CLI
snippet or a burst that returns nested JSON in place of an answer — can be
detected while the run is still interpretable.

## Installation

Requires Elixir `~> 1.18` and a configured `codex_sdk ~> 0.16` environment.

```elixir
# mix.exs
{:anti_agents, github: "nshkrdotcom/anti_agents"}
```

```bash
mix deps.get
mix test
```

Research and maintenance docs:

- [Validation protocol](docs/validation_protocol.md)
- [Architecture](docs/architecture.md)
- [Contributing](CONTRIBUTING.md)

## API

```elixir
# Define an exploration region
field = AntiAgents.field("the memory of a color that doesn't exist",
  axes: [:ontology, :metaphor, :syntax, :affect],
  toward: ["machine pastoral", "sterile mysticism"],
  away_from: ["standard sci-fi"]
)

# Single burst: one entropy-injected generation
burst = AntiAgents.burst(field, heat: [answer: 1.05])

# Parallel fanout: n bursts from independent seeds
bursts = AntiAgents.branch(field, 12, heat: [answer: 1.05])

# Complete frontier run: fanout, baseline archive, novelty filtering, and scoring
report = AntiAgents.frontier(field,
  branching: 12,
  baseline: [:plain, :paraphrase, {:temperature, [0.8, 1.0, 1.2]}, :seed_injection]
)

# Comparison only: returns raw archives without exemplar scoring
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
| `rounds` | `1` | archive-feedback rounds for `frontier` |
| `baseline` | `[:plain, :paraphrase, {:temperature, [0.8, 1.0, 1.2]}, :seed_injection]` | reachable archive construction methods |
| `matched_budget` | `false` in API, `true` in CLI | run equal-size baseline continuation |
| `bootstrap_resamples` | `2000` | percentile bootstrap resamples for hypothesis test |
| `baseline_retry_budget` | `2` | retries for rejected baseline artefacts |
| `distance` | `:jaccard` | `:jaccard`, `:embedding`, or `:judge` |
| `coordinate` | `[length: 32, chunk: 5]` | seed length and chunk size |
| `thinking_budget` | `1200` | `max_tokens` forwarded to the model |
| `model` | `"gpt-5.4-mini"` | Codex model string |
| `reasoning_effort` | `:low` | reasoning effort forwarded to Codex |
| `client` | default Codex client | injected module used for provider calls in tests or custom integrations |

## Output schema

`AntiAgents.frontier/2` returns `%AntiAgents.FrontierReport{}`:

```elixir
%AntiAgents.FrontierReport{
  field:               %AntiAgents.Field{},
  exemplars:           [%AntiAgents.BurstResult{}, ...],  # accepted frontier bursts
  reachable_archive:   [%AntiAgents.BurstResult{}, ...],  # accepted baseline cells
  matched_baseline_archive: [%AntiAgents.BurstResult{}, ...],
  rejected_duplicates: [%AntiAgents.BurstResult{}, ...],  # duplicate/reachable/rejected burst attempts
  reachable_hits:      [%{descriptor: ..., reason: :reachable, score: ...}, ...],
  mapping_traces:      [%{"decisions" => [...]}, ...],     # audit trail for all frontier attempts
  frontier_cell_count: 2,
  reachable_cell_count: 4,
  novel_frontier_cell_count: 2,
  adjusted_novel_frontier_cell_count: 2.0,
  matched_baseline_cell_count: 1,
  hypothesis_test: %{
    delta_distinct_cells: 1,
    bootstrap_ci_95: [0.0, 2.0],
    rejects_null: false,
    n_resamples: 2000
  },
  baseline_retry_count: 0,
  baseline_permanent_loss_count: 0,
  baseline_loss_adjustment: 0.0,
  rounds: 1,
  round_summaries: [%{round: 1, attempted: 8, accepted: 6}],
  stagnation_at_round: nil,
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

The composite score weights novelty more heavily than coherence:

```
overall = 0.50 × baseline_distance
        + 0.25 × frontier_distance
        + 0.15 × seed_coverage
        + 0.10 × coherence
```

`baseline_distance` and `frontier_distance` are computed as
`1 − max_similarity` against the reachable and frontier archives respectively.
The distance backend is pluggable:

- `jaccard` — lexical token-set Jaccard; transparent and default for local QC.
- `embedding` — cosine similarity over vectors from an injected embedding client.
- `judge` — explicit LLM-as-judge path; returns an error unless a judge client is
  configured.

Near-duplicate detection uses a similarity threshold of `0.91`.

Descriptor cells are buckets over
`{length, sentence_count, affect, abstraction, semantic_cluster}` used for
archive-membership testing. `semantic_cluster` degrades to `:unknown` when no
embedding centroids are fitted. Seed coverage is deliberately excluded from cell
identity; including it would allow SSoT outputs to appear novel merely because
baselines carry no mapping trace.

## CLI

```bash
mix anti_agents.frontier "the memory of a color that doesn't exist" \
  --verbose \
  --heartbeat-ms 5000 \
  --branching 12 \
  --rounds 2 \
  --temperature 1.18 \
  --model gpt-5.4-mini \
  --reasoning low \
  --baseline 'plain,paraphrase,temp:0.8|1.0' \
  --matched-budget \
  --bootstrap-resamples 2000 \
  --baseline-retry-budget 2 \
  --distance jaccard \
  --toward "machine pastoral" \
  --away-from "standard sci-fi" \
  --preview-chars 180 \
  --out trace.json
```

Passing `--dry-run` prints the resolved run configuration without invoking the
model. The `--verbose` flag produces human-readable progress reporting: the
total LLM-call plan, the current stage, `LLM n/total`, the purpose of each
baseline or frontier call, heartbeats describing in-flight work, and truncated
input/output previews. Preview length is controlled by `--preview-chars N`.

The `--out` path receives a structured JSON trace containing the synthesis
claim under test, run parameters, the evidence summary (`hypothesis_test`,
`novel_frontier_cell_count`, `adjusted_novel_frontier_cell_count`,
`mean_seed_coverage`), the clean `reachable_archive`, the
`matched_baseline_archive`, and the per-exemplar mapping audit trails.

For multi-field evidence, use:

```bash
mix anti_agents.benchmark --fields priv/benchmarks/fields_v1.json --dry-run
mix anti_agents.benchmark \
  --fields priv/benchmarks/fields_v1.json \
  --verbose \
  --heartbeat-ms 5000 \
  --preview-chars 180 \
  --out tmp/benchmark.json
```

Benchmark verbose output reports the global benchmark run number, field number,
overall completed LLM calls, local field-level call count, active stage purpose,
in-flight heartbeat state, and truncated prompt/output previews. A repeated
`Plan: 3 LLM calls` line is therefore not a new benchmark total; it is the
local plan for the current field/repetition and is prefixed with
`benchmark run X/Y field=...` to make that explicit.

## Anti-collapse policy

In the absence of explicit checks, SSoT-style prompts tend to collapse: the
model selects a single global theme from the first seed chunk and ignores the
remainder of the string. `anti_agents` therefore rejects any burst in which:

- the emitted `random_string` is a copy of the host coordinate nonce;
- the emitted `random_string` is excessively short or highly repetitive;
- the emitted `random_string` duplicates that of another frontier burst in the same run;
- any decision references an invalid chunk or supplies an incorrect hash;
- only one distinct chunk index appears across all verified mapping decisions; or
- fewer than `max(2, ⌈chunk_count / 3⌉)` distinct chunks are verified.

When the backend returns unstructured plain text for a burst call, the output
is retained in the trace with status `:parse_error`; it is never promoted into
a frontier exemplar by means of a synthesised mapping.

## Limitations

The package should be regarded as a live research harness rather than a
completed benchmark implementation.

**Descriptor quality.** The current archive descriptors are deliberately
simple: a semantic fingerprint, structural buckets, an affect band, an
abstraction level, a degraded semantic-cluster slot, and a seed-usage profile.
These descriptors suffice for verifying pipeline behaviour but do not substitute
for NoveltyBench's full evaluation protocol or for a learned behaviour
descriptor.

**Distance quality.** Distance is pluggable, but the default benchmark path
still uses lexical Jaccard because it is transparent and cheap. Embedding and
judge backends exist as explicit paths, but cited results should state which
backend was used and whether provider-specific embeddings were configured.

**Model dependence.** The SSoT paper emphasises that the method depends on
reasoning capability. Smaller or weaker models may fail to generate useful
random strings, execute local mappings, or avoid prefix-only strategies. The
package exposes `seed_coverage` and rejection reasons so that such failures
remain visible.

**Prompt and schema fragility.** Live LLMs occasionally return prompt echoes,
malformed nested JSON, or SDK or tutorial text. `anti_agents` rejects these
artefacts, yet the necessity of such guards is itself an experimental finding:
traceability is a prerequisite for studying diversity.

**Semantic versus latent exploration.** The present implementation is an
inference-time semantic-exploration backend. It explores the model's
reachable output manifold through controlled entropy and archive pressure; it
does not yet implement activation-space, LoRA, SVF, or weight-space steering.

**Inverted supervision.** The process-supervision walker model from `0020` is
not implemented in this pass. Current parallelism uses `Task.async_stream` plus
archive-feedback rounds.

**Single-answer tasks.** As with the original SSoT work, the method is
intended for tasks admitting multiple acceptable outputs or probabilistic
requirements. It is not intended for factual lookup, proof obligations, or
tasks with a single correct answer.

## Paper crosswalk

The following table maps the principal concepts of the SSoT paper onto their
realisation in this package:

| Paper concept | Realisation in this package |
|---------------|-----------------------------|
| PIF/DAG distinction | The present README frames `anti_agents` as a DAG/frontier harness rather than a PIF sampler. |
| SSoT two-stage instruction | The burst prompt requests `random_string`, `mapping`, and `answer`. |
| Full parallelisability | `AntiAgents.branch/3` and baseline-archive construction are implemented with `Task.async_stream`. |
| NoveltyBench comparison against baseline, paraphrase, and temperature | `AntiAgents.frontier/2` constructs a reachable archive from `:plain`, `:paraphrase`, `:seed_injection`, and `{:temperature, [...]}`. |
| DAG strategy: template plus local random selection | `mapping.decisions` requires chunk-local axis decisions over ontology, metaphor, syntax, affect, contradiction, and closure, with host-verifiable `hash` and `choice` fields. |
| Simple SSoT prompt components | The prompt contract preserves explicit string generation, manipulation, and final-answer extraction. |
| External-randomness and tool-call limitations | Host nonces serve only as trace identifiers; the model must emit its own `random_string`, and no model-visible tool calls are required. |
| Bias propagation from lazy prefix use | The anti-collapse policy rejects prefix-only mappings, low verified coverage, nonce copying, repetitive strings, and duplicate model-generated random strings. |
| Reasoning-capability dependence | The README and trace surface `reasoning_effort`, `thinking_budget`, `seed_coverage`, and all rejection reasons. |

The principal extension beyond the paper is **counterfactual frontier
accounting**: SSoT outputs are not considered diverse merely by virtue of
differing from one another. They are compared against a clean reachable
archive, and only cells that lie outside that archive are credited as
frontier expansion.

## Credits

The concept of an anti-agents SDK — no entities, high temperature, and
coverage over task completion — was proposed by
[@threepointone](https://x.com/threepointone/status/2046373376990605423) on X
(20 April 2026). That motivating vision points toward true model-side
steering; this package currently implements the semantic-space frontier-search
substrate and treats activation-, adapter-, and weight-space steering as future
work.

## References

[^1]: Misaki, Kou, and Akiba, Takuya. "String Seed of Thought: Prompting LLMs for Distribution-Faithful and Diverse Generation." arXiv:2510.21150, 2025. https://arxiv.org/abs/2510.21150

## License

MIT — Copyright © 2026 nshkrdotcom
