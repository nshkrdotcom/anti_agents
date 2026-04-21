# Contributing

Run the full verification alias before committing:

```bash
mix verify
```

`mix verify` runs formatting, warning-as-error compilation, tests, Dialyzer, and
the benchmark dry-run plan:

```bash
mix anti_agents.benchmark --fields priv/benchmarks/fields_v1.json --dry-run
```

Live benchmark runs call the configured Codex provider. Keep default runs small
unless an experiment explicitly opts into larger cost with `--expensive`.
