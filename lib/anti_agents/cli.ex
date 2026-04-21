defmodule AntiAgents.CLI do
  @moduledoc false

  @switches [
    dry_run: :boolean,
    include_raw: :boolean,
    verbose: :boolean,
    branching: :integer,
    concurrency: :integer,
    heartbeat_ms: :integer,
    preview_chars: :integer,
    timeout_ms: :integer,
    temperature: :float,
    seed_temperature: :float,
    assembly_temperature: :float,
    thinking_budget: :integer,
    chunk: :integer,
    length: :integer,
    model: :string,
    reasoning: :string,
    baseline: :string,
    out: :string,
    toward: :keep,
    away_from: :keep
  ]

  @aliases [
    b: :branching,
    c: :concurrency,
    m: :model,
    o: :out,
    t: :temperature
  ]

  def parse_frontier_args(args) when is_list(args) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {opts, prompt_parts, []} ->
        prompt = prompt_parts |> Enum.join(" ") |> String.trim()

        if prompt == "" do
          {:error, usage()}
        else
          {:ok, {prompt, frontier_opts(opts)}}
        end

      {_opts, _prompt_parts, invalid} ->
        {:error, "Invalid options: #{inspect(invalid)}\n\n#{usage()}"}
    end
  end

  def usage do
    """
    Usage:
      mix anti_agents.frontier "field prompt" [options]

    Common options:
      --branching N           frontier burst count, default 8
      --temperature FLOAT     answer/model temperature request, default 1.05
      --model MODEL           default gpt-5.4-mini
      --reasoning EFFORT      default low
      --baseline LIST         plain,paraphrase,seed_injection,temp:0.8|1.0|1.2
      --out PATH              write JSON trace to PATH
      --verbose               emit step-by-step progress and heartbeat logs
      --heartbeat-ms N        verbose heartbeat interval, default 5000
      --preview-chars N       chars shown from prompt/output previews, default 180
      --dry-run               print run config without calling Codex
    """
  end

  defp frontier_opts(opts) do
    answer_temperature = Keyword.get(opts, :temperature, 1.05)

    [
      dry_run: Keyword.get(opts, :dry_run, false),
      include_raw: Keyword.get(opts, :include_raw, false),
      verbose: Keyword.get(opts, :verbose, false),
      out: Keyword.get(opts, :out),
      field: [
        toward: Keyword.get_values(opts, :toward),
        away_from: Keyword.get_values(opts, :away_from)
      ],
      branching: Keyword.get(opts, :branching, 8),
      concurrency: Keyword.get(opts, :concurrency, System.schedulers_online()),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, 5_000),
      preview_chars: Keyword.get(opts, :preview_chars, 180),
      timeout_ms: Keyword.get(opts, :timeout_ms, 120_000),
      model: Keyword.get(opts, :model, AntiAgents.CodexConfig.default_model()),
      reasoning_effort:
        opts
        |> Keyword.get(:reasoning, AntiAgents.CodexConfig.default_reasoning_effort())
        |> AntiAgents.CodexConfig.normalize_reasoning_effort(),
      heat: [
        seed: Keyword.get(opts, :seed_temperature, 1.3),
        assembly: Keyword.get(opts, :assembly_temperature, 1.15),
        answer: answer_temperature
      ],
      thinking_budget: Keyword.get(opts, :thinking_budget, 1200),
      coordinate: [
        length: Keyword.get(opts, :length, 32),
        chunk: Keyword.get(opts, :chunk, 5),
        mapping: :local_rolling_hash
      ],
      baseline: parse_baseline(Keyword.get(opts, :baseline))
    ]
  end

  defp parse_baseline(nil),
    do: [:plain, :paraphrase, {:temperature, [0.8, 1.0, 1.2]}, :seed_injection]

  defp parse_baseline(text) when is_binary(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.flat_map(&parse_baseline_entry/1)
  end

  defp parse_baseline_entry("plain"), do: [:plain]
  defp parse_baseline_entry("paraphrase"), do: [:paraphrase]
  defp parse_baseline_entry("seed_injection"), do: [:seed_injection]

  defp parse_baseline_entry("temp:" <> temps) do
    [{:temperature, parse_temperature_list(temps)}]
  end

  defp parse_baseline_entry("temperature:" <> temps) do
    [{:temperature, parse_temperature_list(temps)}]
  end

  defp parse_baseline_entry(_unknown), do: []

  defp parse_temperature_list(temps) do
    temps
    |> String.split("|", trim: true)
    |> Enum.map(&String.to_float/1)
  end
end
