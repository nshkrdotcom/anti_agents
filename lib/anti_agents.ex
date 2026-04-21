defmodule AntiAgents do
  @moduledoc """
  Anti-agents frontier engine.

  This module exposes only frontier primitives: field, burst, branch, frontier, and compare.
  There are no agent/task abstractions in this API.
  """

  alias AntiAgents.{BurstResult, Bursts, Field, Frontier}

  @type heat_opts :: [
          {:seed, float()}
          | {:assembly, float()}
          | {:answer, float()}
          | list
        ]

  @type frontier_opts :: keyword()
  @type burst_output :: BurstResult.t()
  @type frontier_report :: AntiAgents.FrontierReport.t()

  @doc """
  Construct a field (exploration region).
  """
  @spec field(String.t(), keyword()) :: Field.t()
  def field(prompt, opts \\ []) when is_binary(prompt) do
    Field.new(prompt, opts)
  end

  @doc """
  Produce one burst from one coordinate.
  """
  @spec burst(Field.t(), frontier_opts()) :: burst_output()
  def burst(field, opts \\ []), do: Bursts.burst(field, opts)

  @doc """
  Produce several bursts in parallel from the same field.
  """
  @spec branch(Field.t(), pos_integer(), frontier_opts()) :: [burst_output()]
  def branch(field, n, opts \\ []), do: Bursts.branch(field, n, opts)

  @doc """
  Compare one frontier run against baseline reachable output.
  """
  @spec compare(Field.t(), frontier_opts()) :: map()
  def compare(field, opts \\ []), do: Frontier.compare(field, opts)

  @doc """
  Expand an archive from one field with branch/novelty policy and explicit outputs.
  """
  @spec frontier(Field.t(), frontier_opts()) :: frontier_report()
  def frontier(field, opts \\ []), do: Frontier.frontier(field, opts)
end

defmodule AntiAgents.Field do
  @moduledoc """
  Field value object: prompt + exploration axes and steering hints.
  """

  @enforce_keys [:prompt]
  defstruct [
    :prompt,
    axes: [:ontology, :metaphor, :syntax, :affect, :contradiction, :closure],
    toward: [],
    away_from: []
  ]

  @type t :: %__MODULE__{
          prompt: String.t(),
          axes: [atom()],
          toward: [String.t()],
          away_from: [String.t()]
        }

  @doc """
  Build a normalized field.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(prompt, opts \\ []) when is_binary(prompt) do
    axes =
      normalize_axes(
        Keyword.get(opts, :axes, [
          :ontology,
          :metaphor,
          :syntax,
          :affect,
          :contradiction,
          :closure
        ])
      )

    toward = Keyword.get(opts, :toward, [])
    away_from = Keyword.get(opts, :away_from, [])

    %__MODULE__{
      prompt: prompt,
      axes: axes,
      toward: List.wrap(toward),
      away_from: List.wrap(away_from)
    }
  end

  defp normalize_axes(axes) do
    axes
    |> List.wrap()
    |> Enum.map(&normalize_axis/1)
    |> Enum.uniq()
  end

  defp normalize_axis(axis) when is_atom(axis), do: axis
  defp normalize_axis(axis) when is_binary(axis), do: String.to_atom(String.downcase(axis))
  defp normalize_axis(_axis), do: :other
end

defmodule AntiAgents.BurstResult do
  @moduledoc """
  Structured result returned by `AntiAgents.burst/2` and `AntiAgents.branch/3`.
  """

  @type score :: %{
          optional(:baseline_distance) => float(),
          optional(:frontier_distance) => float(),
          optional(:seed_coverage) => float(),
          optional(:coherence) => float(),
          optional(:overall) => float()
        }

  defstruct [
    :field,
    :seed,
    :random_string,
    :mapping_trace,
    :answer,
    :raw_output,
    :status,
    :rejection_reason,
    mapping_verification: %{},
    score: %{},
    descriptor: %{},
    coherence: 0.0,
    seed_coverage: 0.0
  ]

  @type t :: %__MODULE__{
          field: AntiAgents.Field.t(),
          seed: String.t(),
          random_string: String.t(),
          mapping_trace: map(),
          mapping_verification: map(),
          answer: String.t(),
          raw_output: String.t(),
          status: :accepted | :rejected | :parse_error | :provider_error,
          rejection_reason: String.t() | nil,
          score: score(),
          descriptor: map(),
          coherence: float(),
          seed_coverage: float()
        }
end

defmodule AntiAgents.FrontierReport do
  @moduledoc """
  Frontier summary returned by `AntiAgents.frontier/2`.
  """

  defstruct [
    :field,
    exemplars: [],
    reachable_archive: [],
    frontier_cell_count: 0,
    reachable_cell_count: 0,
    novel_frontier_cell_count: 0,
    adjusted_novel_frontier_cell_count: 0.0,
    coverage_delta: 0.0,
    baseline_retry_count: 0,
    baseline_permanent_loss_count: 0,
    baseline_loss_adjustment: 0.0,
    matched_baseline_archive: [],
    matched_baseline_cell_count: 0,
    hypothesis_test: %{},
    rounds: 1,
    round_summaries: [],
    stagnation_at_round: nil,
    schema_rejected_count: 0,
    invalid_mapping_count: 0,
    duplicate_random_string_count: 0,
    reachable_hits: [],
    rejected_duplicates: [],
    mapping_traces: [],
    metrics: %{}
  ]

  @type t :: %__MODULE__{
          field: AntiAgents.Field.t(),
          exemplars: [AntiAgents.BurstResult.t()],
          reachable_archive: [AntiAgents.BurstResult.t()],
          frontier_cell_count: non_neg_integer(),
          reachable_cell_count: non_neg_integer(),
          novel_frontier_cell_count: non_neg_integer(),
          adjusted_novel_frontier_cell_count: float(),
          coverage_delta: float(),
          baseline_retry_count: non_neg_integer(),
          baseline_permanent_loss_count: non_neg_integer(),
          baseline_loss_adjustment: float(),
          matched_baseline_archive: [AntiAgents.BurstResult.t()],
          matched_baseline_cell_count: non_neg_integer(),
          hypothesis_test: map(),
          rounds: pos_integer(),
          round_summaries: [map()],
          stagnation_at_round: pos_integer() | nil,
          schema_rejected_count: non_neg_integer(),
          invalid_mapping_count: non_neg_integer(),
          duplicate_random_string_count: non_neg_integer(),
          reachable_hits: [map()],
          rejected_duplicates: [AntiAgents.BurstResult.t()],
          mapping_traces: [map()],
          metrics: %{
            distinct: integer(),
            coherence: float(),
            seed_coverage: float(),
            archive_coverage: float()
          }
        }
end

defmodule AntiAgents.Client do
  @moduledoc false
  @callback complete(String.t(), keyword()) :: {:ok, any()} | {:error, any()}
end

defmodule AntiAgents.CodexConfig do
  @moduledoc false

  @default_model "gpt-5.4-mini"
  @default_reasoning_effort :low

  def default_model, do: @default_model
  def default_reasoning_effort, do: @default_reasoning_effort

  def model(opts) do
    opts
    |> get_option(:model)
    |> fallback(fetch_codex_opt(opts, :model))
    |> fallback(@default_model)
  end

  def reasoning_effort(opts) do
    opts
    |> get_option(:reasoning_effort)
    |> fallback(fetch_codex_opt(opts, :reasoning_effort))
    |> fallback(fetch_codex_opt(opts, :reasoning))
    |> fallback(@default_reasoning_effort)
    |> normalize_reasoning_effort()
  end

  def codex_opts(opts) when is_list(opts) do
    base = opts |> Keyword.get(:codex_opts, []) |> normalize_keyword()

    if Keyword.has_key?(base, :model_payload) do
      base
    else
      base
      |> Keyword.drop([:model, :reasoning, :reasoning_effort])
      |> Keyword.put(:model_payload, model_payload(model(opts), reasoning_effort(opts)))
    end
  end

  def model_payload(model, effort) do
    %{
      provider: :codex,
      requested_model: model,
      resolved_model: model,
      reasoning: Atom.to_string(effort),
      reasoning_effort: nil,
      normalized_reasoning_effort: nil
    }
  end

  def temperature_config_overrides(opts) do
    [{"temperature", AntiAgents.Prompt.response_temperature(opts)}]
  end

  def merge_config_overrides(opts, turn_opts) do
    turn_opts
    |> Map.get(:config_overrides, Map.get(turn_opts, "config_overrides", []))
    |> List.wrap()
    |> Kernel.++(get_option(opts, :config_overrides) |> List.wrap())
    |> Kernel.++(temperature_config_overrides(opts))
  end

  def normalize_reasoning_effort(value) when is_atom(value), do: value

  def normalize_reasoning_effort(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.to_atom()
  end

  def normalize_reasoning_effort(_value), do: @default_reasoning_effort

  defp fetch_codex_opt(opts, key) do
    opts
    |> get_option(:codex_opts)
    |> case do
      nil -> nil
      codex_opts -> codex_opts |> normalize_keyword() |> Keyword.get(key)
    end
  end

  defp normalize_keyword(nil), do: []
  defp normalize_keyword(opts) when is_list(opts), do: normalize_keyword_keys(opts)

  defp normalize_keyword(opts) when is_map(opts),
    do: opts |> Map.to_list() |> normalize_keyword_keys()

  defp normalize_keyword(_opts), do: []

  defp normalize_keyword_keys(opts) do
    Enum.map(opts, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      pair -> pair
    end)
  end

  defp get_option(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp get_option(opts, key) when is_map(opts),
    do: Map.get(opts, key, Map.get(opts, Atom.to_string(key)))

  defp get_option(_opts, _key), do: nil

  defp fallback(nil, value), do: value
  defp fallback("", value), do: value
  defp fallback(value, _fallback), do: value
end

defmodule AntiAgents.CodexClient do
  @moduledoc """
  Default codex_sdk-backed provider for burst and baseline generation.
  """

  @behaviour AntiAgents.Client

  @impl true
  def complete(prompt, opts) when is_binary(prompt) and is_list(opts) do
    codex_module = Keyword.get(opts, :codex_module, Codex)
    agent_module = Keyword.get(opts, :agent_module, Codex.Agent)
    run_config_module = Keyword.get(opts, :run_config_module, Codex.RunConfig)
    agent_runner_module = Keyword.get(opts, :agent_runner_module, Codex.AgentRunner)
    options_module = Keyword.get(opts, :options_module, Codex.Options)
    thread_options_module = Keyword.get(opts, :thread_options_module, Codex.Thread.Options)

    codex_opts = AntiAgents.CodexConfig.codex_opts(opts)
    thread_opts = Keyword.get(opts, :thread_opts, [])
    run_config_opts = Keyword.get(opts, :run_config, [])
    agent_opts = Keyword.get(opts, :agent, [])
    input = Keyword.get(opts, :input, prompt)
    agent_map = normalize_struct_or_map(agent_opts)
    run_config_map = normalize_struct_or_map(run_config_opts)

    model_settings =
      Keyword.get(opts, :model_settings) ||
        model_settings_from(run_config_opts) ||
        AntiAgents.Prompt.model_settings(opts)

    agent_attrs =
      agent_map
      |> Map.merge(%{instructions: prompt})
      |> Map.put(:model_settings, Map.get(agent_map, :model_settings, model_settings))

    run_config_attrs =
      run_config_map
      |> Map.merge(%{
        max_turns: Map.get(run_config_map, :max_turns, Keyword.get(opts, :max_turns, 1)),
        model_settings: Map.get(run_config_map, :model_settings, model_settings),
        workflow: Map.get(run_config_map, :workflow, "anti_agents"),
        group: Map.get(run_config_map, :group, "frontier"),
        trace_id: Map.get(run_config_map, :trace_id, default_trace_id()),
        trace_include_sensitive_data:
          Map.get(run_config_map, :trace_include_sensitive_data, false),
        tracing_disabled: Map.get(run_config_map, :tracing_disabled, false)
      })

    output_schema = Keyword.get(opts, :output_schema)
    base_turn_opts = opts |> Keyword.get(:turn_opts, %{}) |> normalize_struct_or_map()

    turn_opts =
      base_turn_opts
      |> maybe_put(:output_schema, output_schema)
      |> Map.put(
        :config_overrides,
        AntiAgents.CodexConfig.merge_config_overrides(opts, base_turn_opts)
      )

    with {:ok, codex_opts} <- options_module.new(codex_opts),
         {:ok, thread_opts} <- thread_options_module.new(thread_opts),
         {:ok, agent} <- agent_module.new(agent_attrs),
         {:ok, run_config} <- run_config_module.new(run_config_attrs),
         {:ok, thread} <- codex_module.start_thread(codex_opts, thread_opts),
         {:ok, result} <-
           agent_runner_module.run(thread, input, %{
             agent: agent,
             run_config: run_config,
             turn_opts: turn_opts
           }) do
      AntiAgents.Scoring.extract_text(result)
    end
  end

  defp normalize_struct_or_map(%_{} = struct), do: Map.from_struct(struct)
  defp normalize_struct_or_map(map) when is_map(map), do: map
  defp normalize_struct_or_map(list) when is_list(list), do: Map.new(list)
  defp normalize_struct_or_map(_), do: %{}

  defp model_settings_from(%_{} = run_config), do: Map.get(run_config, :model_settings)
  defp model_settings_from(list) when is_list(list), do: Keyword.get(list, :model_settings)
  defp model_settings_from(map) when is_map(map), do: Map.get(map, :model_settings)
  defp model_settings_from(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_trace_id do
    "anti-agents-" <> Integer.to_string(System.unique_integer([:positive]))
  end
end

defmodule AntiAgents.Prompt do
  @moduledoc false

  def burst_prompt(field, opts) do
    chunk_size = get_coordinate(opts, :chunk, 5)
    axes = Enum.map_join(field.axes, ", ", &to_string/1)
    toward = render_list(field.toward)
    away_from = render_list(field.away_from)

    """
    You are not a persona. Produce exactly one exploration.

    1. Internally generate a fresh random string, then emit it as random_string.
    2. Return a single JSON object with keys:
       - random_string: the exact internally generated random string
       - mapping: an object with a decisions array
       - answer: the final answer text
       Each mapping.decisions entry must include axis, chunk, hash, choice, and value.
       Split random_string into fixed-size chunks of #{chunk_size} and use these axes: #{axes}.
       For each decision:
       - chunk is a zero-based chunk index into random_string
       - chunk_text is the selected chunk from random_string
       - hash = sum of UTF-8 byte values in "<chunk>:<chunk_text>" modulo 997
       - choice = hash modulo 7
       - value explains how that local chunk affects the answer for the axis
    3. No markdown, no code fences, and no commentary outside the JSON object.

    Rules:
    - Do not copy the coordinate nonce as random_string.
    - Use multiple chunks in local decisions, not one global theme choice.
    - Do not use only the first character or first chunk.
    - No tool calls.
    - No task-completion language.
    - Optimize for novelty under a minimal coherence floor.

    Field prompt:
    #{field.prompt}

    Steering:
    toward=#{toward}
    away_from=#{away_from}
    #{archive_feedback(opts)}
    """
  end

  defp archive_feedback(opts) do
    case get_option(opts, :steering_delta) do
      nil ->
        ""

      %{text: text} when is_binary(text) ->
        "Archive feedback: #{text}"

      text when is_binary(text) ->
        "Archive feedback: #{text}"

      _other ->
        ""
    end
  end

  def field_input(field, opts) do
    seed = get_seed(opts)
    chunk_size = get_coordinate(opts, :chunk, 5)

    """
    Coordinate nonce: #{seed}
    Field prompt: #{field.prompt}
    Axes: #{Enum.map_join(field.axes, ", ", &to_string/1)}
    Chunk size: #{chunk_size}
    Toward: #{render_list(field.toward)}
    Away from: #{render_list(field.away_from)}
    """
  end

  def baseline_prompt(field, method, opts) do
    base = "Field: #{field.prompt}\n\n"
    seed = get_seed(opts)

    plain_rule =
      "\n\nReturn only the generated answer text itself. Do not label the answer, explain, rewrite the prompt, offer a refined prompt, mention AntiAgents, mention CLI/mix commands, use code fences, return JSON/XML, or include random_string/mapping."

    case method do
      :plain ->
        "#{base}Write a concise, high-coherence creative answer for the field.#{plain_rule}"

      :paraphrase ->
        "#{base}Write a concise, faithful answer that paraphrases the field's idea.#{plain_rule}"

      :seed_injection ->
        "#{base}Write a concise, coherent answer. Use this seed internally to force a different framing: #{seed}. Do not print the seed.#{plain_rule}"

      {:temperature, temps} when is_list(temps) ->
        "#{base}Write a concise, coherent creative answer for the field.#{plain_rule}"

      _ ->
        "#{base}Write a concise, coherent creative answer for the field.#{plain_rule}"
    end
  end

  def baseline_input(field, method, opts) do
    seed_line =
      if method == :seed_injection do
        "\nSeed: #{get_seed(opts)}"
      else
        ""
      end

    """
    Field prompt: #{field.prompt}
    Baseline method: #{baseline_method_name(method)}
    Toward: #{render_list(field.toward)}
    Away from: #{render_list(field.away_from)}#{seed_line}
    """
  end

  def response_temperature(opts) do
    heat = get_option(opts, :heat)

    cond do
      is_number(heat) -> heat
      is_list(heat) -> Keyword.get(heat, :answer, 1.0)
      is_map(heat) -> Map.get(heat, :answer, 1.0)
      true -> 1.0
    end
  end

  def model_settings(opts) do
    temperature = response_temperature(opts)
    max_tokens = get_option(opts, :thinking_budget) || 1200

    {:ok, settings} =
      Codex.ModelSettings.new(%{
        temperature: temperature,
        max_tokens: max_tokens,
        provider: :responses
      })

    settings
  end

  def run_config(opts) do
    max_turns = get_option(opts, :max_turns) || 1
    model = get_option(opts, :run_config_model)
    workflow = get_option(opts, :workflow) || "anti_agents"
    group = get_option(opts, :group) || "frontier"
    trace_id = get_option(opts, :trace_id) || default_trace_id()

    [
      max_turns: max_turns,
      model: model,
      model_settings: model_settings(opts),
      workflow: workflow,
      group: group,
      trace_id: trace_id,
      trace_include_sensitive_data: false,
      tracing_disabled: false
    ]
  end

  defp get_seed(opts) do
    seed = get_option(opts, :seed)

    case seed do
      nil ->
        random_length = get_coordinate(opts, :length, 32)
        allowed = "abcdefghijklmnopqrstuvwxyz0123456789"
        max_index = byte_size(allowed)

        1..random_length
        |> Enum.reduce(<<>>, fn _, acc ->
          index = :rand.uniform(max_index) - 1
          <<acc::binary, :binary.part(allowed, index, 1)::binary>>
        end)
        |> to_string()

      seed ->
        seed
    end
  end

  defp get_option(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get_option(opts, key), do: Map.get(opts, key)

  defp get_coordinate(opts, key, default) do
    coordinate = get_option(opts, :coordinate)

    value =
      cond do
        is_list(coordinate) -> Keyword.get(coordinate, key)
        is_map(coordinate) -> Map.get(coordinate, key)
        true -> nil
      end

    value || default
  end

  defp render_list([]), do: "none"
  defp render_list(values), do: Enum.join(List.wrap(values), ", ")

  defp baseline_method_name({:temperature, temp}), do: "temperature:#{temp}"
  defp baseline_method_name(method), do: to_string(method)

  defp default_trace_id do
    "anti-agents-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  def output_schema(_opts) do
    %{
      "type" => "object",
      "properties" => %{
        "random_string" => %{"type" => "string"},
        "mapping" => %{
          "type" => "object",
          "properties" => %{
            "decisions" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "axis" => %{"type" => "string"},
                  "chunk" => %{"type" => "integer"},
                  "hash" => %{"type" => "integer"},
                  "choice" => %{"type" => "integer"},
                  "value" => %{"type" => "string"}
                },
                "required" => ["axis", "chunk", "hash", "choice", "value"],
                "additionalProperties" => false
              }
            }
          },
          "required" => ["decisions"],
          "additionalProperties" => false
        },
        "answer" => %{"type" => "string"}
      },
      "required" => ["random_string", "mapping", "answer"],
      "additionalProperties" => false
    }
  end
end

defmodule AntiAgents.Scoring do
  @moduledoc false

  alias AntiAgents.Distance

  def extract_text(%{final_response: final_response}), do: extract_text(final_response)
  def extract_text(%{content: text}) when is_binary(text), do: {:ok, text}
  def extract_text(%{"content" => text}) when is_binary(text), do: {:ok, text}
  def extract_text(%{text: text}) when is_binary(text), do: {:ok, text}
  def extract_text(%{message: %{content: text}}) when is_binary(text), do: {:ok, text}
  def extract_text(%Codex.Items.AgentMessage{text: text}) when is_binary(text), do: {:ok, text}
  def extract_text(text) when is_binary(text), do: {:ok, text}
  def extract_text(other), do: {:ok, inspect(other)}

  def parse_burst_output(output) when is_binary(output) do
    case parse_json_output(output) do
      {:ok, parsed} ->
        {:ok, parsed}

      _ ->
        parse_tagged_output(output)
    end
  end

  def parse_burst_output(_output), do: {:error, :invalid_output}

  defp parse_tagged_output(output) do
    case {capture(output, "random_string"), capture(output, "mapping"), capture(output, "answer")} do
      {{:ok, random_string}, {:ok, mapping_text}, {:ok, answer}} ->
        decode_tagged_output(random_string, mapping_text, answer)

      {{:error, reason}, _, _} ->
        {:error, reason}

      {_, {:error, reason}, _} ->
        {:error, reason}

      {_, _, {:error, reason}} ->
        {:error, reason}
    end
  end

  defp decode_tagged_output(random_string, mapping_text, answer) do
    case Jason.decode(mapping_text) do
      {:ok, mapping} ->
        {:ok,
         %{
           random_string: String.trim(random_string),
           mapping: mapping,
           answer: String.trim(answer)
         }}

      {:error, reason} ->
        {:error, {:bad_mapping_json, reason}}
    end
  end

  def descriptor(text, mapping, seed, chunk_count, verification \\ nil) do
    structural = structural_descriptor(text)
    affect = affect_band(text)
    abstraction = abstraction_level(text)
    seed_profile = seed_profile(mapping, seed, chunk_count, verification)

    %{
      semantic: semantic_fingerprint(text),
      structural: structural,
      affect: affect,
      abstraction: abstraction,
      seed_profile: seed_profile,
      cell: novelty_cell(structural, affect, abstraction, seed_profile)
    }
  end

  def seed_coverage(mapping, chunk_count) do
    used_chunks = parse_mapping_coverage(mapping).chunk_count
    denom = max(1, chunk_count)

    used_chunks
    |> Kernel./(denom)
    |> min(1.0)
    |> Float.round(3)
  end

  def fit_centroids(vectors, k) when is_list(vectors) and is_integer(k) and k > 0 do
    vectors
    |> Enum.uniq()
    |> Enum.take(k)
  end

  def fit_centroids(_vectors, _k), do: []

  def local_hash(_axis, chunk_text, chunk_index) do
    "#{chunk_index}:#{chunk_text}"
    |> :binary.bin_to_list()
    |> Enum.sum()
    |> rem(997)
  end

  def verify_mapping(mapping, random_string, chunk_size) when is_map(mapping) do
    decisions = Map.get(mapping, "decisions", Map.get(mapping, :decisions, []))
    chunks = chunks(random_string, chunk_size)

    {verified, invalid_reasons} =
      decisions
      |> List.wrap()
      |> Enum.reduce({[], []}, fn decision, {verified, reasons} ->
        case verify_decision(decision, chunks, chunk_size) do
          {:ok, normalized} -> {[normalized | verified], reasons}
          {:error, reason} -> {verified, [reason | reasons]}
        end
      end)

    used_chunks =
      verified
      |> Enum.map(& &1["chunk"])
      |> Enum.uniq()
      |> Enum.sort()

    invalid_reasons =
      invalid_reasons
      |> maybe_add_missing_decisions(decisions)
      |> Enum.uniq()
      |> Enum.sort()

    chunk_count = max(1, length(chunks))
    coverage = Float.round(length(used_chunks) / chunk_count, 3)

    %{
      valid?: invalid_reasons == [],
      coverage: coverage,
      verified_chunk_count: length(used_chunks),
      chunk_count: chunk_count,
      used_chunks: used_chunks,
      invalid_reasons: invalid_reasons,
      decisions: Enum.reverse(verified)
    }
  end

  def verify_mapping(_mapping, _random_string, chunk_size) do
    chunk_count = max(1, chunk_count("", chunk_size))

    %{
      valid?: false,
      coverage: 0.0,
      verified_chunk_count: 0,
      chunk_count: chunk_count,
      used_chunks: [],
      invalid_reasons: ["invalid_mapping"],
      decisions: []
    }
  end

  def verified_anti_collapse_fail?(verification) when is_map(verification) do
    chunk_count = Map.get(verification, :chunk_count, 1)
    used_count = Map.get(verification, :verified_chunk_count, 0)

    prefix_only? = used_count == 1
    poor_coverage? = used_count < minimum_verified_chunks(chunk_count)

    prefix_only? or poor_coverage?
  end

  def score_weights do
    %{
      baseline_distance: 0.50,
      frontier_distance: 0.25,
      seed_coverage: 0.15,
      coherence: 0.10
    }
  end

  def score(candidate, reachable, frontier, opts \\ []) do
    baseline_distance = 1.0 - maximum_similarity(candidate.answer, reachable, opts)
    frontier_distance = 1.0 - maximum_similarity(candidate.answer, frontier, opts)
    coverage = candidate.seed_coverage
    coherence = candidate.coherence
    weights = score_weights()

    overall =
      weights.baseline_distance * baseline_distance +
        weights.frontier_distance * frontier_distance +
        weights.seed_coverage * coverage +
        weights.coherence * coherence

    %{
      baseline_distance: baseline_distance,
      frontier_distance: frontier_distance,
      seed_coverage: coverage,
      coherence: coherence,
      overall: Float.round(overall, 4)
    }
  end

  def similarity(a, b, opts \\ []) do
    backend = opts |> Keyword.get(:distance, :jaccard) |> Distance.resolve()

    case backend.pairwise(a, b, opts) do
      {:ok, value} -> value
      {:error, _reason} -> Distance.Jaccard.similarity(a, b)
    end
  end

  def maximum_similarity(_text, []), do: 0.0

  def maximum_similarity(text, bursts, opts \\ []) when is_list(bursts) do
    Enum.map(bursts, fn
      %AntiAgents.BurstResult{answer: answer} -> similarity(answer, text, opts)
      %{answer: answer} -> similarity(answer, text, opts)
    end)
    |> Enum.max(fn -> 0.0 end)
  end

  def near_duplicate?(text, bursts, threshold \\ 0.91, opts \\ []) do
    maximum_similarity(text, bursts, opts) > threshold
  end

  def artifact_answer?(answer) when is_binary(answer) do
    answer
    |> String.trim()
    |> artifact_answer_text?()
  end

  def artifact_answer?(_answer), do: false

  def clean_plain_answer(output) when is_binary(output) do
    answer =
      output
      |> String.trim()
      |> unwrap_answer_json()

    cond do
      answer == "" ->
        {:error, :empty_answer}

      artifact_answer?(answer) ->
        {:error, :artifact_answer}

      true ->
        {:ok, answer}
    end
  end

  def clean_plain_answer(_output), do: {:error, :invalid_answer}

  def duplicate?(_candidate, []), do: false
  def duplicate?(candidate, bursts), do: near_duplicate?(candidate.answer, bursts)

  def parse_mapping_coverage(mapping) when is_map(mapping) do
    with %{"decisions" => decisions} <- mapping,
         true <- is_list(decisions) do
      chunk_indexes =
        decisions
        |> Enum.flat_map(&extract_decision_chunks/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      %{axis_count: length(decisions), chunk_count: length(chunk_indexes)}
    else
      _ ->
        %{axis_count: 0, chunk_count: 0}
    end
  end

  def parse_mapping_coverage(_), do: %{axis_count: 0, chunk_count: 0}

  def anti_collapse_fail?(mapping, chunk_count) do
    cov = parse_mapping_coverage(mapping)
    prefix_only? = cov.axis_count > 0 && cov.chunk_count == 1
    poor_coverage? = cov.chunk_count < minimum_verified_chunks(chunk_count)
    prefix_only? or poor_coverage?
  end

  def coherence(answer) do
    words = token_set(answer)

    case words do
      [] ->
        0.0

      _ ->
        word_count = length(words)
        vocab_ratio = length(Enum.uniq(words)) / word_count
        punctuation = String.length(String.replace(answer, ~r/[^\p{P}]/u, ""))
        len_factor = min(1.0, String.length(answer) / 240)

        base =
          0.35 * vocab_ratio + 0.25 * min(1.0, punctuation / max(1, word_count)) +
            0.4 * len_factor

        Float.round(max(0.0, min(1.0, base)), 4)
    end
  end

  def synthesize_mapping(answer, axes, seed, chunk_count) do
    axes
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {axis, index} ->
      chunk = rem(index, max(1, chunk_count))
      sample = String.slice(answer, index * 12, 12)
      basis = "#{seed}|#{axis}|#{chunk}|#{sample}"

      %{
        "axis" => to_string(axis),
        "chunk" => chunk,
        "value" => hash_token(basis)
      }
    end)
    |> then(&%{"decisions" => &1})
  end

  defp verify_decision(decision, chunks, _chunk_size) when is_map(decision) do
    axis = decision_value(decision, "axis")
    chunk = decision_value(decision, "chunk") |> integer_value()
    supplied_hash = decision_value(decision, "hash") |> integer_value()

    cond do
      axis in [nil, ""] ->
        {:error, "missing_axis"}

      is_nil(chunk) ->
        {:error, "invalid_chunk"}

      chunk < 0 or chunk >= length(chunks) ->
        {:error, "invalid_chunk"}

      is_nil(supplied_hash) ->
        {:error, "missing_hash"}

      true ->
        chunk_text = Enum.at(chunks, chunk)
        expected_hash = local_hash(axis, chunk_text, chunk)

        if supplied_hash == expected_hash do
          {:ok,
           %{
             "axis" => to_string(axis),
             "chunk" => chunk,
             "hash" => supplied_hash,
             "choice" => integer_value(decision_value(decision, "choice")),
             "value" => to_string(decision_value(decision, "value") || ""),
             "chunk_text" => chunk_text
           }}
        else
          {:error, "invalid_hash"}
        end
    end
  end

  defp verify_decision(_decision, _chunks, _chunk_size), do: {:error, "invalid_decision"}

  defp decision_value(decision, key) do
    Map.get(decision, key, Map.get(decision, String.to_atom(key)))
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp chunks(random_string, chunk_size) when is_binary(random_string) do
    size = if is_integer(chunk_size) and chunk_size > 0, do: chunk_size, else: 1

    random_string
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
    |> case do
      [] -> [""]
      chunks -> chunks
    end
  end

  defp chunks(_random_string, _chunk_size), do: [""]

  defp chunk_count(random_string, chunk_size), do: length(chunks(random_string, chunk_size))

  defp maybe_add_missing_decisions(reasons, decisions) do
    if is_list(decisions) and decisions != [] do
      reasons
    else
      ["missing_decisions" | reasons]
    end
  end

  defp minimum_verified_chunks(chunk_count) do
    max(2, ceil_div(max(1, chunk_count), 3))
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp capture(text, tag) do
    regex = ~r/<#{tag}>(.*?)<\/#{tag}>/s

    case Regex.run(regex, text, capture: :all_but_first) do
      [captured] -> {:ok, captured}
      _ -> {:error, {:missing_tag, tag}}
    end
  end

  defp parse_json_output(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"random_string" => random_string, "mapping" => mapping, "answer" => answer}} ->
        normalize_parsed_json(random_string, mapping, answer)

      {:ok, _other} ->
        {:error, :not_structured_json}

      {:error, _reason} ->
        {:error, :not_json}
    end
  end

  defp normalize_parsed_json(random_string, mapping, answer) when is_binary(answer) do
    answer
    |> String.trim()
    |> Jason.decode()
    |> case do
      {:ok,
       %{"random_string" => nested_random, "mapping" => nested_mapping, "answer" => nested_answer}} ->
        normalize_parsed_json(nested_random, nested_mapping, nested_answer)

      {:ok,
       %{
         "random_string" => nested_random,
         "mapping" => %{"answer" => nested_answer} = nested_mapping
       }} ->
        normalize_parsed_json(nested_random, Map.delete(nested_mapping, "answer"), nested_answer)

      _other ->
        {:ok,
         %{
           random_string: String.trim(to_string(random_string)),
           mapping: mapping,
           answer: String.trim(answer)
         }}
    end
  end

  defp normalize_parsed_json(random_string, mapping, answer) do
    {:ok,
     %{
       random_string: String.trim(to_string(random_string)),
       mapping: mapping,
       answer: String.trim(to_string(answer))
     }}
  end

  defp hash_token(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp novelty_cell(structural, affect, abstraction, _seed_profile) do
    %{
      length: length_bucket(structural.length),
      sentence_count: sentence_bucket(structural.sentence_count),
      affect: affect,
      abstraction: abstraction,
      semantic_cluster: :unknown
    }
  end

  defp length_bucket(n) when n < 80, do: :short
  defp length_bucket(n) when n < 160, do: :medium
  defp length_bucket(n) when n < 280, do: :long
  defp length_bucket(_), do: :extended

  defp sentence_bucket(n) when n <= 1, do: :single
  defp sentence_bucket(n) when n <= 3, do: :small
  defp sentence_bucket(n) when n <= 6, do: :medium
  defp sentence_bucket(_), do: :large

  defp count_words(text), do: token_set(text) |> length()
  defp sentence_count(text), do: String.split(text, ~r/[.!?]+/, trim: true) |> length()
  defp token_set(text), do: String.downcase(text) |> String.split(~r/[^[:alnum:]]+/, trim: true)

  defp artifact_answer_text?(""), do: false

  defp artifact_answer_text?(text) do
    String.contains?(text, "<random_string>") or
      String.contains?(text, "<mapping>") or
      String.contains?(text, "Coordinate nonce:") or
      String.contains?(text, "Field prompt:") or
      sdk_or_prompt_artifact?(text) or
      malformed_control_payload?(text) or
      control_json_payload?(text)
  end

  defp sdk_or_prompt_artifact?(text) do
    normalized = String.downcase(text)

    Enum.any?(
      [
        "antiagents.",
        "anti_agents.",
        "mix anti_agents",
        "```",
        "equivalent cli",
        "if you want",
        "refined version of the prompt",
        "refined prompt you can use",
        "use this as the prompt",
        "use this field",
        "rewrite the prompt",
        "format this as"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp malformed_control_payload?(text) do
    has_random = String.contains?(text, ["\"random_string\"", "random_string:"])
    has_mapping = String.contains?(text, ["\"mapping\"", "mapping:"])
    has_decisions = String.contains?(text, ["\"decisions\"", "decisions:"])

    has_random and has_mapping and has_decisions
  end

  defp unwrap_answer_json(text) do
    case Jason.decode(text) do
      {:ok, %{"answer" => answer} = decoded} when is_binary(answer) and map_size(decoded) == 1 ->
        String.trim(answer)

      _other ->
        text
    end
  end

  defp control_json_payload?(text) do
    case Jason.decode(text) do
      {:ok, decoded} ->
        control_key_count(decoded) >= 2

      {:error, _reason} ->
        false
    end
  end

  defp control_key_count(value) when is_map(value) do
    local =
      value
      |> Map.keys()
      |> Enum.count(&(to_string(&1) in control_payload_keys()))

    nested =
      value
      |> Map.values()
      |> Enum.map(&control_key_count/1)
      |> Enum.sum()

    local + nested
  end

  defp control_key_count(value) when is_list(value) do
    value
    |> Enum.map(&control_key_count/1)
    |> Enum.sum()
  end

  defp control_key_count(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.starts_with?(trimmed, ["{", "["]) do
      case Jason.decode(trimmed) do
        {:ok, decoded} -> control_key_count(decoded)
        {:error, _reason} -> 0
      end
    else
      0
    end
  end

  defp control_key_count(_value), do: 0

  defp control_payload_keys do
    ~w(
      answer
      anti_collapse
      exemplars
      mapping
      mapping_trace
      mapping_traces
      mode
      random_string
      reachable_hits
      rejected_duplicates
      run_config
      schema_version
      synthesis
    )
  end

  defp semantic_fingerprint(text) do
    :crypto.hash(:sha256, String.downcase(text))
    |> Base.encode16()
  end

  defp structural_descriptor(text) do
    %{
      length: String.length(text),
      word_count: count_words(text),
      sentence_count: sentence_count(text)
    }
  end

  defp affect_band(text) do
    score = affective_tokens(text)

    cond do
      score > 0.12 -> :high
      score > 0.03 -> :medium
      true -> :low
    end
  end

  defp affective_tokens(text) do
    pos_words = ~w(growth harmony calm clarity resonance)
    neg_words = ~w(harsh violent fracture confusion)

    words = token_set(text)
    pos = Enum.count(words, &(&1 in pos_words))
    neg = Enum.count(words, &(&1 in neg_words))

    (pos - neg) / max(1, Enum.count(words))
  end

  defp abstraction_level(text) do
    words = token_set(text)

    abstract_words =
      ~w(absence impossible memory language perception spectrum contradiction longing unreal real)

    abstract_count = Enum.count(words, &(&1 in abstract_words))
    ratio = abstract_count / max(1, length(words))

    cond do
      ratio > 0.12 -> :high
      ratio > 0.04 or String.length(text) > 220 -> :mid
      true -> :low
    end
  end

  defp seed_profile(mapping, seed, chunk_count, verification) do
    coverage =
      case verification do
        %{coverage: verified_coverage} -> verified_coverage
        _ -> seed_coverage(mapping, chunk_count)
      end

    chunk_count_map = parse_mapping_coverage(mapping).chunk_count

    %{
      style: "local_sum_mod_hash",
      scope: coverage,
      chunk_count: chunk_count_map,
      chunk_total: chunk_count,
      random_string_length: byte_size(seed),
      mode: "global_and_local",
      verified?: match?(%{valid?: true}, verification)
    }
  end

  def enrich(result, descriptor, seed_coverage) do
    result
    |> Map.put(:descriptor, descriptor)
    |> Map.put(:seed_coverage, seed_coverage)
    |> Map.put(:coherence, coherence(result.answer))
  end

  defp extract_decision_chunks(decision) when is_map(decision),
    do: [decision["chunk"], decision[:chunk]]

  defp extract_decision_chunks(_), do: []
end

defmodule AntiAgents.Bursts do
  @moduledoc false

  alias AntiAgents.{BurstResult, CodexClient, Field, Progress, Prompt, Scoring}

  @type burst_output :: BurstResult.t()

  @spec burst(Field.t(), keyword()) :: burst_output()
  def burst(%Field{} = field, opts \\ []) do
    options = default_burst_options(opts)
    client = Keyword.get(options, :client, CodexClient)
    seed = get_seed(options)
    chunk_size = get_coordinate(options, :chunk, 5)

    prompt = Prompt.burst_prompt(field, options)
    input = Prompt.field_input(field, options)

    Progress.event(options, :burst_call_start, %{
      index: Keyword.get(options, :burst_index),
      llm_index: progress_llm_index(options),
      llm_total: Keyword.get(options, :progress_llm_total),
      total: Keyword.get(options, :burst_total),
      model: Keyword.get(options, :model),
      temperature: Prompt.response_temperature(options),
      input_preview: input
    })

    case client.complete(prompt, completion_opts(field, prompt, input, options)) do
      {:ok, raw} ->
        burst = burst_from_raw(field, seed, chunk_size, raw)

        Progress.event(options, :burst_call_done, %{
          index: Keyword.get(options, :burst_index),
          llm_index: progress_llm_index(options),
          llm_total: Keyword.get(options, :progress_llm_total),
          total: Keyword.get(options, :burst_total),
          status: burst.status,
          seed_coverage: burst.seed_coverage,
          answer_length: String.length(burst.answer),
          output_preview: burst.answer
        })

        burst

      {:error, reason} ->
        Progress.event(options, :burst_call_error, %{
          index: Keyword.get(options, :burst_index),
          llm_index: progress_llm_index(options),
          llm_total: Keyword.get(options, :progress_llm_total),
          total: Keyword.get(options, :burst_total),
          reason: inspect(reason)
        })

        provider_error_burst(field, seed, reason)
    end
  end

  @spec branch(Field.t(), pos_integer(), keyword()) :: [burst_output()]
  def branch(%Field{} = field, n, opts) when is_integer(n) and n > 0 do
    options = default_burst_options(opts)
    concurrency = Keyword.get(options, :concurrency, System.schedulers_online())
    timeout = Keyword.get(options, :timeout_ms, 120_000)
    burst_opts = Keyword.delete(options, :seed)

    Progress.event(options, :branch_start, %{
      count: n,
      concurrency: concurrency,
      timeout_ms: timeout
    })

    1..n
    |> Task.async_stream(
      fn index ->
        burst_opts
        |> Keyword.put(:burst_index, index)
        |> Keyword.put(:burst_total, n)
        |> then(&burst(field, &1))
      end,
      max_concurrency: concurrency,
      timeout: timeout,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, burst} ->
        burst

      {:exit, reason} ->
        %BurstResult{
          field: field,
          seed: get_seed(options),
          random_string: "",
          mapping_trace: %{},
          answer: "",
          raw_output: "",
          status: :provider_error,
          rejection_reason: inspect(reason)
        }
    end)
    |> tap(fn bursts ->
      Progress.event(options, :branch_done, %{
        count: length(bursts),
        accepted: Enum.count(bursts, &(&1.status == :accepted)),
        rejected: Enum.count(bursts, &(&1.status == :rejected)),
        errors: Enum.count(bursts, &(&1.status in [:provider_error, :parse_error]))
      })
    end)
  end

  defp completion_opts(_field, prompt, input, opts) do
    Keyword.merge(
      [
        input: input,
        model: Keyword.get(opts, :model, AntiAgents.CodexConfig.default_model()),
        reasoning_effort:
          Keyword.get(opts, :reasoning_effort, AntiAgents.CodexConfig.default_reasoning_effort()),
        codex_opts: Keyword.get(opts, :codex_opts, []),
        thread_opts: Keyword.get(opts, :thread_opts, []),
        model_settings: Keyword.get(opts, :model_settings, Prompt.model_settings(opts)),
        run_config: Prompt.run_config(opts),
        turn_opts: turn_opts(opts),
        agent: [instructions: prompt],
        output_schema: Prompt.output_schema(opts)
      ],
      Keyword.get(opts, :client_opts, [])
    )
  end

  defp turn_opts(opts) do
    [
      timeout_ms: Keyword.get(opts, :timeout_ms),
      stream_idle_timeout_ms: Keyword.get(opts, :stream_idle_timeout_ms)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp burst_from_raw(field, seed, chunk_size, raw) do
    {:ok, text} = Scoring.extract_text(raw)

    case Scoring.parse_burst_output(text) do
      {:ok, parsed} ->
        chunk_count = chunk_count(parsed.random_string, chunk_size)
        structured_burst(field, seed, chunk_count, chunk_size, text, parsed)

      {:error, reason} ->
        unstructured_burst(field, seed, text, reason)
    end
  end

  defp structured_burst(field, seed, chunk_count, chunk_size, text, parsed) do
    mapping = Map.get(parsed, :mapping, %{})
    verification = Scoring.verify_mapping(mapping, parsed.random_string, chunk_size)

    base =
      %BurstResult{
        field: field,
        seed: seed,
        random_string: parsed.random_string,
        mapping_trace: mapping,
        mapping_verification: verification,
        answer: parsed.answer,
        raw_output: text,
        status: :accepted,
        rejection_reason: nil
      }
      |> Map.put(:seed_coverage, verification.coverage)

    descriptor =
      Scoring.descriptor(base.answer, mapping, base.random_string, chunk_count, verification)

    candidate = Scoring.enrich(base, descriptor, base.seed_coverage)

    maybe_reject_candidate(candidate, seed, verification)
  end

  defp maybe_reject_candidate(candidate, host_seed, verification) do
    cond do
      Scoring.artifact_answer?(candidate.answer) ->
        %{
          candidate
          | status: :rejected,
            rejection_reason: "artifact answer / nested control payload"
        }

      candidate.random_string == host_seed ->
        %{
          candidate
          | status: :rejected,
            rejection_reason: "random string copied coordinate nonce"
        }

      reason = random_string_quality_reason(candidate.random_string) ->
        %{
          candidate
          | status: :rejected,
            rejection_reason: reason
        }

      verification.valid? == false ->
        %{
          candidate
          | status: :rejected,
            rejection_reason: "invalid mapping: #{Enum.join(verification.invalid_reasons, ",")}"
        }

      Scoring.verified_anti_collapse_fail?(verification) ->
        %{candidate | status: :rejected, rejection_reason: "low seed coverage / chunk collapse"}

      true ->
        candidate
    end
  end

  defp unstructured_burst(field, seed, text, reason) do
    trimmed = String.trim(text)

    if trimmed == "" do
      parse_error_burst(field, seed, reason)
    else
      unstructured_parse_error_burst(field, seed, trimmed, reason)
    end
  end

  defp unstructured_parse_error_burst(field, seed, text, reason) do
    %BurstResult{
      field: field,
      seed: seed,
      random_string: "",
      mapping_trace: %{},
      mapping_verification: %{
        valid?: false,
        coverage: 0.0,
        verified_chunk_count: 0,
        chunk_count: 0,
        used_chunks: [],
        invalid_reasons: ["unstructured_output"],
        decisions: []
      },
      answer: text,
      raw_output: text,
      status: :parse_error,
      rejection_reason:
        "unstructured model output; schema required for SSoT evidence: #{inspect(reason)}"
    }
  end

  defp random_string_quality_reason(random_string) when is_binary(random_string) do
    graphemes = String.graphemes(random_string)
    unique_count = graphemes |> Enum.uniq() |> length()
    max_run = max_repeated_run(graphemes)

    cond do
      String.length(random_string) < 8 ->
        "random string too short"

      unique_count < 4 or max_run >= 5 ->
        "random string too repetitive"

      true ->
        nil
    end
  end

  defp random_string_quality_reason(_random_string), do: "invalid random string"

  defp max_repeated_run([]), do: 0

  defp max_repeated_run([first | rest]) do
    {_current, current_run, max_run} =
      Enum.reduce(rest, {first, 1, 1}, fn grapheme, {previous, run, max_run} ->
        if grapheme == previous do
          run = run + 1
          {grapheme, run, max(max_run, run)}
        else
          {grapheme, 1, max_run}
        end
      end)

    max(current_run, max_run)
  end

  defp parse_error_burst(field, seed, reason) do
    %BurstResult{
      field: field,
      seed: seed,
      random_string: "",
      mapping_trace: %{},
      mapping_verification: %{},
      answer: "",
      raw_output: "",
      status: :parse_error,
      rejection_reason: inspect(reason)
    }
  end

  defp provider_error_burst(field, seed, reason) do
    %BurstResult{
      field: field,
      seed: seed,
      random_string: "",
      mapping_trace: %{},
      mapping_verification: %{},
      answer: "",
      raw_output: "",
      status: :provider_error,
      rejection_reason: inspect(reason)
    }
  end

  defp default_burst_options(opts) do
    defaults = [
      heat: [seed: 1.3, assembly: 1.15, answer: 1.05],
      coordinate: [length: 32, chunk: 5, mapping: :local_sum_mod_hash],
      thinking_budget: 1200,
      client: CodexClient,
      codex_opts: [],
      thread_opts: [],
      client_opts: [],
      max_turns: 1,
      model: AntiAgents.CodexConfig.default_model(),
      reasoning_effort: AntiAgents.CodexConfig.default_reasoning_effort()
    ]

    defaults
    |> Keyword.merge(opts)
    |> Keyword.put_new(:seed, generate_seed(opts))
  end

  defp generate_seed(opts) do
    length = get_coordinate(opts, :length, 32)
    allowed = "abcdefghijklmnopqrstuvwxyz0123456789"

    Enum.map_join(1..length, "", fn _ ->
      String.at(allowed, :rand.uniform(String.length(allowed)) - 1)
    end)
  end

  defp get_seed(opts) when is_list(opts), do: Keyword.get(opts, :seed, "seed")

  defp get_coordinate(opts, key, default), do: get_in(opts, [:coordinate, key]) || default

  defp progress_llm_index(opts) do
    offset = Keyword.get(opts, :progress_llm_offset, 0)

    case Keyword.get(opts, :burst_index) do
      index when is_integer(index) -> offset + index
      other -> other
    end
  end

  defp chunk_count(seed, chunk_size) when is_integer(chunk_size) and chunk_size > 0 do
    seed
    |> String.length()
    |> Kernel./(chunk_size)
    |> Float.ceil()
    |> trunc()
    |> max(1)
  end

  defp chunk_count(_seed, _chunk_size), do: 1
end

defmodule AntiAgents.Frontier do
  @moduledoc false

  alias AntiAgents.{BurstResult, Bursts, Field, FrontierReport, Progress, Prompt, Scoring}
  alias AntiAgents.Statistics

  @type compare_output :: %{
          field: Field.t(),
          reachable_archive: [BurstResult.t()],
          frontier_archive: [BurstResult.t()],
          novel_frontier_cell_count: non_neg_integer(),
          baseline_stats: map(),
          reachable_hits: [map()],
          duplicates: [BurstResult.t()]
        }

  def compare(%Field{} = field, opts \\ []) do
    branch_count = Keyword.get(opts, :branching, 8)
    rounds = opts |> Keyword.get(:rounds, 1) |> max(1)
    matched_budget? = Keyword.get(opts, :matched_budget, false)

    baseline_opts =
      Keyword.get(opts, :baseline, [
        :plain,
        :paraphrase,
        {:temperature, [0.8, 1.0, 1.2]},
        :seed_injection
      ])

    baseline_count = baseline_method_count(baseline_opts)
    planned_frontier_calls = branch_count * rounds
    planned_matched_calls = if matched_budget?, do: planned_frontier_calls, else: 0
    total_llm_calls = baseline_count + planned_frontier_calls + planned_matched_calls

    Progress.event(opts, :run_plan, %{
      baseline_calls: baseline_count,
      frontier_bursts: planned_frontier_calls,
      matched_baseline_calls: planned_matched_calls,
      total_llm_calls: total_llm_calls,
      concurrency: Keyword.get(opts, :concurrency, System.schedulers_online())
    })

    Progress.event(opts, :compare_start, %{
      branching: branch_count,
      baseline_methods: baseline_count
    })

    Progress.event(opts, :baseline_start, %{methods: baseline_count})
    {reachable, baseline_stats} = baseline_bursts(field, baseline_opts, opts, total_llm_calls)

    Progress.event(opts, :baseline_done, Map.put(baseline_stats, :accepted, length(reachable)))
    Progress.event(opts, :frontier_start, %{branching: planned_frontier_calls})

    {frontier_bursts, round_summaries, stagnation_at_round} =
      frontier_rounds(field, branch_count, rounds, opts, baseline_count, total_llm_calls)

    accepted_frontier_count = Enum.count(frontier_bursts, &(&1.status == :accepted))

    {matched_baseline, matched_stats} =
      if matched_budget? and accepted_frontier_count > 0 do
        matched_baseline(
          field,
          baseline_opts,
          Keyword.merge(opts,
            matched_baseline_count: accepted_frontier_count,
            progress_llm_offset: baseline_count + planned_frontier_calls,
            progress_llm_total: total_llm_calls
          )
        )
      else
        {[], baseline_attempt_stats(0, 0)}
      end

    Progress.event(opts, :frontier_done, %{
      total: length(frontier_bursts),
      accepted: Enum.count(frontier_bursts, &(&1.status == :accepted)),
      rejected: Enum.count(frontier_bursts, &(&1.status == :rejected))
    })

    %{
      field: field,
      reachable_archive: reachable,
      frontier_archive: frontier_bursts,
      matched_baseline_archive: matched_baseline,
      round_summaries: round_summaries,
      stagnation_at_round: stagnation_at_round,
      rounds: rounds,
      novel_frontier_cell_count: novel_cell_count(frontier_bursts, reachable),
      baseline_stats: merge_baseline_stats([baseline_stats, matched_stats]),
      reachable_hits: reachable_intersections(frontier_bursts, reachable),
      duplicates: duplicates(frontier_bursts)
    }
  end

  def matched_baseline(%Field{} = field, baseline_methods, opts \\ []) do
    count = Keyword.get(opts, :matched_baseline_count, Keyword.get(opts, :branching, 8))

    methods =
      baseline_methods
      |> Enum.flat_map(&expand_method/1)
      |> cycle_methods(count)

    baseline_bursts(field, methods, opts, Keyword.get(opts, :progress_llm_total, count))
  end

  defp frontier_rounds(field, branch_count, rounds, opts, baseline_count, total_llm_calls) do
    1..rounds
    |> Enum.reduce_while({[], [], nil}, fn round, {bursts_acc, summaries_acc, _stagnation} ->
      accepted_so_far = Enum.filter(bursts_acc, &(&1.status == :accepted))

      round_opts =
        opts
        |> Keyword.put(:progress_llm_offset, baseline_count + (round - 1) * branch_count)
        |> Keyword.put(:progress_llm_total, total_llm_calls)
        |> Keyword.put(:round, round)
        |> maybe_put_steering_delta(archive_steering_delta(accepted_so_far, round))

      bursts = Bursts.branch(field, branch_count, round_opts)
      accepted_count = Enum.count(bursts, &(&1.status == :accepted))

      summary = %{
        round: round,
        attempted: length(bursts),
        accepted: accepted_count,
        rejected: Enum.count(bursts, &(&1.status == :rejected)),
        errors: Enum.count(bursts, &(&1.status in [:provider_error, :parse_error]))
      }

      updated_bursts = bursts_acc ++ bursts
      updated_summaries = summaries_acc ++ [summary]

      if accepted_count == 0 do
        {:halt, {updated_bursts, updated_summaries, round}}
      else
        {:cont, {updated_bursts, updated_summaries, nil}}
      end
    end)
  end

  defp maybe_put_steering_delta(opts, nil), do: opts
  defp maybe_put_steering_delta(opts, delta), do: Keyword.put(opts, :steering_delta, delta)

  defp archive_steering_delta(_accepted_so_far, 1), do: nil
  defp archive_steering_delta([], _round), do: nil

  defp archive_steering_delta(accepted_so_far, _round) do
    overfilled =
      accepted_so_far
      |> Enum.map(& &1.descriptor.cell)
      |> Enum.frequencies()
      |> Enum.max_by(fn {_cell, count} -> count end, fn -> {nil, 0} end)
      |> elem(0)

    if is_nil(overfilled) do
      nil
    else
      %{
        text:
          "Prefer a descriptor region unlike #{cell_label(overfilled)}; avoid repeating the most populated archive cell."
          |> String.slice(0, 200)
      }
    end
  end

  defp cell_label(cell) when is_map(cell) do
    Enum.map_join(cell, "/", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp cell_label(cell), do: inspect(cell)

  def frontier(%Field{} = field, opts \\ []) do
    report = compare(field, opts)

    {accepted, rejected_duplicates} =
      partition_frontier(report.frontier_archive, report.reachable_archive)

    accepted = Enum.reverse(accepted) |> score_frontier(report.reachable_archive, opts)
    rejected_duplicates = Enum.reverse(rejected_duplicates)

    frontier_cells =
      accepted
      |> Enum.map(& &1.descriptor.cell)
      |> Enum.uniq()

    reachable_hits = reachable_hits(rejected_duplicates, report.reachable_archive)

    reachable_cell_count = distinct_cell_count(report.reachable_archive)
    archive_size = length(report.frontier_archive)
    frontier_cell_count = length(frontier_cells)
    novel_frontier_cell_count = frontier_cell_count

    baseline_loss_adjustment =
      baseline_loss_adjustment(
        report.baseline_stats.permanent_loss_count,
        report.reachable_archive,
        novel_frontier_cell_count
      )

    adjusted_novel_frontier_cell_count =
      max(0.0, Float.round(novel_frontier_cell_count - baseline_loss_adjustment, 3))

    coverage_delta = avg(accepted, :seed_coverage) - avg(report.reachable_archive, :seed_coverage)
    hypothesis_test = hypothesis_test(accepted, report.matched_baseline_archive, opts)

    hypothesis_test =
      maybe_force_null_for_baseline_loss(hypothesis_test, adjusted_novel_frontier_cell_count)

    frontier_report = %FrontierReport{
      field: field,
      exemplars: accepted,
      reachable_archive: report.reachable_archive,
      frontier_cell_count: frontier_cell_count,
      reachable_cell_count: reachable_cell_count,
      novel_frontier_cell_count: novel_frontier_cell_count,
      adjusted_novel_frontier_cell_count: adjusted_novel_frontier_cell_count,
      coverage_delta: Float.round(coverage_delta, 3),
      baseline_retry_count: report.baseline_stats.retry_count,
      baseline_permanent_loss_count: report.baseline_stats.permanent_loss_count,
      baseline_loss_adjustment: baseline_loss_adjustment,
      matched_baseline_archive: report.matched_baseline_archive,
      matched_baseline_cell_count:
        Statistics.distinct_cell_count(report.matched_baseline_archive),
      hypothesis_test: hypothesis_test,
      rounds: report.rounds,
      round_summaries: report.round_summaries,
      stagnation_at_round: report.stagnation_at_round,
      schema_rejected_count: count_status(report.frontier_archive, :parse_error),
      invalid_mapping_count: count_rejection(report.frontier_archive, "invalid mapping"),
      duplicate_random_string_count:
        count_rejection(rejected_duplicates, "duplicate random_string"),
      reachable_hits: reachable_hits,
      rejected_duplicates: rejected_duplicates,
      mapping_traces: Enum.map(report.frontier_archive, & &1.mapping_trace),
      metrics: %{
        distinct: length(frontier_cells),
        coherence: avg(accepted, :coherence),
        seed_coverage: avg(accepted, :seed_coverage),
        archive_coverage: if(archive_size == 0, do: 0.0, else: length(accepted) / archive_size)
      }
    }

    Progress.event(opts, :frontier_report_done, %{
      accepted: length(frontier_report.exemplars),
      rejected: length(frontier_report.rejected_duplicates),
      novel_frontier_cell_count: frontier_report.novel_frontier_cell_count,
      archive_coverage: frontier_report.metrics.archive_coverage,
      seed_coverage: frontier_report.metrics.seed_coverage
    })

    frontier_report
  end

  defp baseline_bursts(field, methods, opts, total_llm_calls) do
    expanded = Enum.flat_map(methods, &expand_method/1)
    concurrency = baseline_concurrency(opts, length(expanded))
    timeout = Keyword.get(opts, :timeout_ms, 120_000)

    results =
      expanded
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {method, index} ->
          baseline_burst(field, method, opts, index, length(expanded), total_llm_calls)
        end,
        max_concurrency: concurrency,
        timeout: timeout,
        ordered: true
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _reason} -> {nil, baseline_attempt_stats(0, 1)}
      end)

    accepted =
      results
      |> Enum.map(fn {burst, _stats} -> burst end)
      |> Enum.reject(&is_nil/1)

    stats =
      results
      |> Enum.map(fn {_burst, stats} -> stats end)
      |> merge_baseline_stats()

    {accepted, stats}
  end

  defp expand_method(:plain), do: [:plain]
  defp expand_method(:paraphrase), do: [:paraphrase]
  defp expand_method(:seed_injection), do: [:seed_injection]
  defp expand_method({:temperature, temp}) when is_number(temp), do: [{:temperature, temp}]

  defp expand_method({:temperature, temps}) when is_list(temps),
    do: Enum.map(temps, &{:temperature, &1})

  defp expand_method(_), do: []

  defp cycle_methods(_methods, count) when count <= 0, do: []
  defp cycle_methods([], _count), do: []

  defp cycle_methods(methods, count) do
    methods
    |> Stream.cycle()
    |> Enum.take(count)
  end

  defp baseline_burst(field, method, opts, index, total, total_llm_calls) do
    client = Keyword.get(opts, :client, AntiAgents.CodexClient)
    method_opts = baseline_method_opts(method, opts)
    input = Prompt.baseline_input(field, method, method_opts)
    retry_budget = Keyword.get(opts, :baseline_retry_budget, 2)

    baseline_burst_attempt(
      %{
        field: field,
        method: method,
        client: client,
        method_opts: method_opts,
        input: input,
        index: index,
        total: total,
        total_llm_calls: total_llm_calls,
        retry_budget: retry_budget
      },
      0,
      baseline_attempt_stats(0, 0)
    )
  end

  defp baseline_burst_attempt(ctx, attempt, stats) do
    prompt =
      ctx.field
      |> Prompt.baseline_prompt(ctx.method, ctx.method_opts)
      |> maybe_strengthen_baseline_prompt(attempt)

    Progress.event(ctx.method_opts, :baseline_call_start, %{
      index: ctx.index,
      llm_index: baseline_llm_index(ctx.method_opts, ctx.index),
      llm_total: ctx.total_llm_calls,
      total: ctx.total,
      method: method_label(ctx.method),
      input_preview: ctx.input
    })

    case ctx.client.complete(prompt, baseline_completion_opts(prompt, ctx.input, ctx.method_opts)) do
      {:ok, raw} ->
        case build_baseline_burst(ctx.field, ctx.method, raw) do
          {:ok, burst} ->
            Progress.event(ctx.method_opts, :baseline_call_done, %{
              index: ctx.index,
              llm_index: baseline_llm_index(ctx.method_opts, ctx.index),
              llm_total: ctx.total_llm_calls,
              method: method_label(ctx.method),
              total: ctx.total,
              answer_length: String.length(burst.answer),
              output_preview: burst.answer
            })

            {burst, stats}

          {:error, reason, preview} ->
            retry_or_reject_baseline(ctx, attempt, stats, reason, preview)
        end

      {:error, reason} ->
        Progress.event(ctx.method_opts, :baseline_call_error, %{
          index: ctx.index,
          llm_index: baseline_llm_index(ctx.method_opts, ctx.index),
          llm_total: ctx.total_llm_calls,
          method: method_label(ctx.method),
          total: ctx.total,
          reason: inspect(reason)
        })

        {nil, Map.update!(stats, :permanent_loss_count, &(&1 + 1))}
    end
  end

  defp baseline_llm_index(opts, index), do: Keyword.get(opts, :progress_llm_offset, 0) + index

  defp retry_or_reject_baseline(ctx, attempt, stats, reason, preview) do
    if attempt < ctx.retry_budget do
      retry_count = attempt + 1

      Progress.event(ctx.method_opts, :baseline_call_retry, %{
        index: ctx.index,
        llm_index: baseline_llm_index(ctx.method_opts, ctx.index),
        llm_total: ctx.total_llm_calls,
        method: method_label(ctx.method),
        total: ctx.total,
        attempt: retry_count,
        retry_budget: ctx.retry_budget,
        reason: inspect(reason),
        output_preview: preview
      })

      baseline_burst_attempt(
        ctx,
        retry_count,
        Map.update!(stats, :retry_count, &(&1 + 1))
      )
    else
      Progress.event(ctx.method_opts, :baseline_call_rejected, %{
        index: ctx.index,
        llm_index: baseline_llm_index(ctx.method_opts, ctx.index),
        llm_total: ctx.total_llm_calls,
        method: method_label(ctx.method),
        total: ctx.total,
        reason: inspect(reason),
        output_preview: preview
      })

      {nil, Map.update!(stats, :permanent_loss_count, &(&1 + 1))}
    end
  end

  defp maybe_strengthen_baseline_prompt(prompt, 0), do: prompt

  defp maybe_strengthen_baseline_prompt(prompt, _attempt) do
    prompt <>
      "\n\nRetry correction: return only the generated answer text. Do not return JSON, code fences, prompt text, field labels, CLI commands, or instructions."
  end

  defp baseline_attempt_stats(retry_count, permanent_loss_count) do
    %{
      retry_count: retry_count,
      permanent_loss_count: permanent_loss_count
    }
  end

  defp merge_baseline_stats(stats) do
    Enum.reduce(stats, baseline_attempt_stats(0, 0), fn stat, acc ->
      %{
        retry_count: acc.retry_count + Map.get(stat, :retry_count, 0),
        permanent_loss_count: acc.permanent_loss_count + Map.get(stat, :permanent_loss_count, 0)
      }
    end)
  end

  defp baseline_method_count(methods) do
    methods
    |> Enum.flat_map(&expand_method/1)
    |> length()
  end

  defp method_label({:temperature, temp}), do: "temperature:#{temp}"
  defp method_label(method), do: to_string(method)

  defp baseline_method_opts({:temperature, temp}, opts) when is_number(temp) do
    Keyword.put(opts, :model_settings, model_settings_with_temperature(opts, temp))
  end

  defp baseline_method_opts(_method, opts), do: opts

  defp build_baseline_burst(field, method, raw) do
    with {:ok, text} <- Scoring.extract_text(raw),
         {:ok, answer} <- Scoring.clean_plain_answer(text) do
      {:ok,
       %BurstResult{
         field: field,
         seed: "baseline",
         random_string: "baseline",
         mapping_trace: %{mode: :baseline, method: method},
         answer: answer,
         raw_output: answer,
         status: :accepted,
         rejection_reason: nil,
         score: %{},
         descriptor: Scoring.descriptor(answer, %{}, "", 1),
         coherence: Scoring.coherence(answer),
         seed_coverage: 0.0
       }}
    else
      {:error, reason} ->
        {:error, reason, raw |> inspect() |> String.slice(0, 500)}
    end
  end

  defp baseline_concurrency(_opts, count) when count <= 1, do: 1

  defp baseline_concurrency(opts, count) do
    opts
    |> Keyword.get(
      :baseline_concurrency,
      Keyword.get(opts, :concurrency, System.schedulers_online())
    )
    |> min(count)
    |> max(1)
  end

  defp score_frontier(accepted, reachable, opts) do
    Enum.map(accepted, fn burst ->
      peers = Enum.reject(accepted, &(&1 == burst))
      Map.put(burst, :score, Scoring.score(burst, reachable, peers, opts))
    end)
  end

  defp baseline_completion_opts(prompt, input, opts) do
    Keyword.merge(
      [
        input: input,
        model: Keyword.get(opts, :model, AntiAgents.CodexConfig.default_model()),
        reasoning_effort:
          Keyword.get(opts, :reasoning_effort, AntiAgents.CodexConfig.default_reasoning_effort()),
        codex_opts: Keyword.get(opts, :codex_opts, []),
        thread_opts: Keyword.get(opts, :thread_opts, []),
        model_settings: Keyword.get(opts, :model_settings, Prompt.model_settings(opts)),
        run_config: Prompt.run_config(Keyword.put(opts, :group, "baseline")),
        turn_opts: turn_opts(opts),
        agent: [instructions: prompt]
      ],
      Keyword.get(opts, :client_opts, [])
    )
  end

  defp turn_opts(opts) do
    [
      timeout_ms: Keyword.get(opts, :timeout_ms),
      stream_idle_timeout_ms: Keyword.get(opts, :stream_idle_timeout_ms)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp frontier_cell_hit?(_burst, []), do: false

  defp frontier_cell_hit?(burst, reachable) do
    Enum.any?(reachable, fn base -> base.descriptor.cell == burst.descriptor.cell end)
  end

  defp partition_frontier(frontier_archive, reachable_archive) do
    {accepted, rejected, _seen_random_strings} =
      Enum.reduce(frontier_archive, {[], [], MapSet.new()}, fn burst,
                                                               {accepted, rejected, seen} ->
        {accepted, rejected, seen} =
          case accept_frontier_burst?(burst, accepted, reachable_archive, seen) do
            {:accept, burst} ->
              {[burst | accepted], rejected, MapSet.put(seen, burst.random_string)}

            {:reject, burst} ->
              {accepted, [burst | rejected], seen}
          end

        {accepted, rejected, seen}
      end)

    {accepted, rejected}
  end

  defp accept_frontier_burst?(%{status: :accepted} = burst, accepted, reachable_archive, seen) do
    cond do
      MapSet.member?(seen, burst.random_string) ->
        {:reject,
         %{burst | status: :rejected, rejection_reason: "duplicate random_string in frontier run"}}

      Scoring.duplicate?(burst, accepted) ->
        {:reject,
         %{burst | status: :rejected, rejection_reason: "near duplicate frontier answer"}}

      frontier_cell_hit?(burst, reachable_archive) ->
        {:reject, %{burst | status: :rejected, rejection_reason: "reachable baseline cell"}}

      true ->
        {:accept, burst}
    end
  end

  defp accept_frontier_burst?(burst, _accepted, _reachable_archive, _seen), do: {:reject, burst}

  defp reachable_intersections(frontier, reachable) do
    Enum.flat_map(frontier, fn burst ->
      if has_descriptor?(burst) and frontier_cell_hit?(burst, reachable) do
        [%{burst: burst, reason: "reachable"}]
      else
        []
      end
    end)
  end

  defp novel_cell_count(frontier, reachable) do
    frontier_cells =
      frontier
      |> Enum.filter(&(&1.status == :accepted and has_descriptor?(&1)))
      |> Enum.map(& &1.descriptor.cell)
      |> MapSet.new()

    reachable_cells =
      reachable
      |> Enum.filter(&has_descriptor?/1)
      |> Enum.map(& &1.descriptor.cell)
      |> MapSet.new()

    frontier_cells
    |> MapSet.difference(reachable_cells)
    |> MapSet.size()
  end

  defp has_descriptor?(%{descriptor: %{cell: _}}), do: true
  defp has_descriptor?(_), do: false

  defp duplicates(frontier), do: Enum.filter(frontier, &(&1.status != :accepted))

  defp distinct_cell_count(bursts) do
    bursts
    |> Enum.map(& &1.descriptor.cell)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  defp baseline_loss_adjustment(0, _reachable, _novel_count), do: 0.0
  defp baseline_loss_adjustment(_loss_count, _reachable, 0), do: 0.0

  defp baseline_loss_adjustment(loss_count, [], novel_count) do
    min(loss_count, novel_count) * 1.0
  end

  defp baseline_loss_adjustment(loss_count, reachable, novel_count) do
    expected_cells_per_lost_call = distinct_cell_count(reachable) / max(1, length(reachable))

    loss_count
    |> Kernel.*(expected_cells_per_lost_call)
    |> min(novel_count)
    |> Float.round(3)
  end

  defp hypothesis_test(frontier, matched_baseline, opts) do
    if Keyword.get(opts, :matched_budget, false) do
      Statistics.hypothesis_test(frontier, matched_baseline,
        resamples: Keyword.get(opts, :bootstrap_resamples, 2_000),
        seed: Keyword.get(opts, :bootstrap_seed, 1)
      )
      |> Map.put(:enabled, true)
    else
      %{
        enabled: false,
        delta_distinct_cells:
          Statistics.distinct_cell_count(frontier) -
            Statistics.distinct_cell_count(matched_baseline),
        bootstrap_ci_95: [0.0, 0.0],
        rejects_null: false,
        matched_baseline_cell_count: Statistics.distinct_cell_count(matched_baseline),
        frontier_cell_count: Statistics.distinct_cell_count(frontier),
        n_resamples: 0
      }
    end
  end

  defp maybe_force_null_for_baseline_loss(hypothesis_test, adjusted_novel_frontier_cell_count)
       when adjusted_novel_frontier_cell_count <= 0 do
    %{hypothesis_test | rejects_null: false}
  end

  defp maybe_force_null_for_baseline_loss(hypothesis_test, _adjusted_novel_frontier_cell_count),
    do: hypothesis_test

  defp count_status(bursts, status), do: Enum.count(bursts, &(&1.status == status))

  defp count_rejection(bursts, needle) do
    Enum.count(bursts, fn burst ->
      burst.rejection_reason
      |> to_string()
      |> String.contains?(needle)
    end)
  end

  defp reachable_hits(accepted, reachable) do
    Enum.reduce(accepted, [], fn burst, acc ->
      if frontier_cell_hit?(burst, reachable) do
        [%{descriptor: burst.descriptor, reason: :reachable, score: burst.score} | acc]
      else
        acc
      end
    end)
  end

  defp avg(items, key) do
    values = Enum.map(items, &Map.get(&1, key))
    if Enum.empty?(values), do: 0.0, else: Enum.sum(values) / length(values)
  end

  defp model_settings_with_temperature(opts, temp) do
    opts
    |> Keyword.put(:heat, answer: temp)
    |> Prompt.model_settings()
  end
end
