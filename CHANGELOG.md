# Changelog

## 2026-04-20

- W1: Added matched-budget hypothesis testing, bootstrap confidence intervals,
  12-field benchmark fixture, and `mix anti_agents.benchmark`.
- W2: Added archive-feedback rounds with per-round summaries and stagnation
  reporting.
- W3: Added pluggable distance backends for Jaccard, embedding, and judge paths;
  descriptor cells now include `semantic_cluster`.
- W4: Reframed public documentation around semantic-space frontier search and
  removed unsupported latent-space claims.
- W5: Added baseline artifact retry, permanent-loss accounting, and adjusted
  novelty reporting.
- W7: Added verification fixtures, trace schema, scoring-weight invariant tests,
  `mix verify`, and contributor verification docs.
- C1: Replaced the semantic-cluster stub with embedding-backed centroid
  assignment and traceable centroid IDs.
- C2: Changed the benchmark headline statistic to per-field mean-delta
  bootstrap plus one-sided sign test; retained pooled cells as diagnostics.
- C3: Added `--diagnostic` and blocked low-budget benchmark runs from being
  reported as evidence.
- C4: Added frontier temperature sweeps, matched-baseline temperature parity,
  and ignored seed/assembly heat warnings.
- C5: Added `priv/profiles/evidence.json` and benchmark `--profile` loading
  with recorded overrides.
- C6: Split matched-baseline retry/loss accounting from reachable-baseline
  accounting.
- C7: Changed archive feedback to positively target underfilled descriptor
  cells.
- C8: Added descriptor saturation metrics and benchmark calibration status.
- C9: Added `mix anti_agents.calibrate --stubbed` as the QC positive control.
- C10: Reserved README evidence reporting until an embedding-backed,
  expensive-gated evidence run is deliberately executed.
