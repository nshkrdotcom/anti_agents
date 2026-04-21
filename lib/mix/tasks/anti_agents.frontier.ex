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
    if Keyword.get(opts, :dry_run, false) do
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
  end

  defp run_opts(opts) do
    Keyword.drop(opts, [:dry_run, :field, :include_raw, :out])
  end

  defp emit_trace(trace, opts) do
    encoded = Jason.encode!(trace, pretty: true)

    case Keyword.get(opts, :out) do
      nil ->
        Mix.shell().info(encoded)

      path ->
        AntiAgents.Trace.write_json!(path, trace)
        Mix.shell().info("Wrote AntiAgents trace to #{path}")
    end
  end
end
