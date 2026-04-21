defmodule Mix.Tasks.AntiAgents.Frontier do
  @moduledoc """
  Run a live AntiAgents frontier experiment through codex_sdk.
  """

  use Mix.Task

  @shortdoc "Runs a traceable live frontier experiment"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case AntiAgents.CLI.parse_frontier_args(args) do
      {:ok, {prompt, opts}} ->
        run_frontier(prompt, opts)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp run_frontier(prompt, opts) do
    AntiAgents.Progress.with_heartbeat(opts, :mix_frontier, fn opts ->
      AntiAgents.Progress.event(opts, :mix_frontier_start, %{
        dry_run: Keyword.get(opts, :dry_run, false),
        field: prompt,
        model: Keyword.get(opts, :model),
        reasoning_effort: Keyword.get(opts, :reasoning_effort)
      })

      if Keyword.get(opts, :dry_run, false) do
        emit_run_plan(opts)

        AntiAgents.Trace.dry_run(prompt, opts)
        |> emit_trace(opts)
      else
        field = AntiAgents.field(prompt, Keyword.get(opts, :field, []))

        report =
          opts
          |> run_opts()
          |> then(&AntiAgents.frontier(field, &1))

        report
        |> AntiAgents.Trace.report(opts)
        |> emit_trace(opts)
      end

      AntiAgents.Progress.event(opts, :mix_frontier_done)
    end)
  end

  defp emit_run_plan(opts) do
    baseline_calls =
      opts
      |> Keyword.get(:baseline, [])
      |> baseline_call_count()

    frontier_bursts = Keyword.get(opts, :branching, 8) * Keyword.get(opts, :rounds, 1)

    matched_baseline_calls =
      if Keyword.get(opts, :matched_budget, true), do: frontier_bursts, else: 0

    AntiAgents.Progress.event(opts, :run_plan, %{
      baseline_calls: baseline_calls,
      frontier_bursts: frontier_bursts,
      matched_baseline_calls: matched_baseline_calls,
      total_llm_calls: baseline_calls + frontier_bursts + matched_baseline_calls,
      concurrency: Keyword.get(opts, :concurrency, System.schedulers_online())
    })
  end

  defp run_opts(opts) do
    Keyword.drop(opts, [:dry_run, :field, :include_raw, :out])
  end

  defp baseline_call_count(methods) do
    methods
    |> Enum.flat_map(&expand_baseline_method/1)
    |> length()
  end

  defp expand_baseline_method(:plain), do: [:plain]
  defp expand_baseline_method(:paraphrase), do: [:paraphrase]
  defp expand_baseline_method(:seed_injection), do: [:seed_injection]

  defp expand_baseline_method({:temperature, temps}) when is_list(temps),
    do: Enum.map(temps, &{:temperature, &1})

  defp expand_baseline_method(_method), do: []

  defp emit_trace(trace, opts) do
    encoded = Jason.encode!(trace, pretty: true)

    case Keyword.get(opts, :out) do
      nil ->
        Mix.shell().info(encoded)

      path ->
        AntiAgents.Trace.write_json!(path, trace)
        AntiAgents.Progress.event(opts, :trace_written, %{path: path})
        Mix.shell().info("Wrote AntiAgents trace to #{path}")
    end
  end
end
