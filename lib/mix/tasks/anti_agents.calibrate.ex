defmodule Mix.Tasks.AntiAgents.Calibrate do
  @moduledoc """
  Run a positive-control calibration for the AntiAgents benchmark.
  """

  use Mix.Task

  @shortdoc "Runs a positive-control AntiAgents calibration"

  @switches [
    stubbed: :boolean,
    out: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        run_calibration(opts)

      {_opts, _args, invalid} ->
        Mix.raise("Invalid options: #{inspect(invalid)}\n\n#{usage()}")
    end
  end

  defp usage do
    """
    Usage:
      mix anti_agents.calibrate --stubbed [--out tmp/calibration.json]

    The stubbed calibration is the QC positive control. Live calibration is
    intentionally not run by default because it spends provider calls.
    """
  end

  defp run_calibration(opts) do
    unless Keyword.get(opts, :stubbed, false) do
      Mix.raise(
        "live calibration is not run by default; pass --stubbed for the QC positive control"
      )
    end

    report = stubbed_report()

    unless get_in(report, ["evidence", "hypothesis_test", "rejects_null"]) do
      Mix.raise(
        "stubbed calibration failed to reject the null; benchmark instrument is miscalibrated"
      )
    end

    emit(report, Keyword.get(opts, :out))
  end

  defp stubbed_report do
    deltas = [2, 2, 1, 1, 2, 2, 1, 1, 2, 1, 2, 1]

    hypothesis =
      deltas
      |> AntiAgents.Statistics.evidence_hypothesis("ok", resamples: 1_000, seed: 99)
      |> json_roundtrip()

    %{
      "schema_version" => 1,
      "mode" => "calibration_report",
      "stubbed" => true,
      "claim" => "positive-control frontier arm must beat matched baseline on per-field deltas",
      "evidence" => %{
        "hypothesis_test" => hypothesis,
        "calibration_status" => "ok"
      }
    }
  end

  defp json_roundtrip(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp emit(report, nil), do: Mix.shell().info(Jason.encode!(report, pretty: true))

  defp emit(report, path) do
    AntiAgents.Trace.write_json!(path, report)
    Mix.shell().info("Wrote AntiAgents calibration trace to #{path}")
  end
end
