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
    delta_frontier: 0.0,
    reachable_hits: [],
    rejected_duplicates: [],
    mapping_traces: [],
    metrics: %{}
  ]

  @type t :: %__MODULE__{
          field: AntiAgents.Field.t(),
          exemplars: [AntiAgents.BurstResult.t()],
          delta_frontier: float(),
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
    2. Prefer a single JSON object with keys:
       - random_string: the exact internally generated random string
       - mapping: an object with a decisions array
       - answer: the final answer text
       The mapping.decisions entries should include chunk-local decisions across the axes.
       Split random_string into fixed-size chunks of #{chunk_size} and use these axes: #{axes}.
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
    """
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

    case method do
      :plain ->
        "#{base}Return a concise, high-coherence answer to the field."

      :paraphrase ->
        "#{base}Return a concise, faithful paraphrase of how you understand the field."

      :seed_injection ->
        "#{base}Use this seed internally to force a different but coherent framing: #{seed}"

      {:temperature, temps} when is_list(temps) ->
        "#{base}Return a concise, coherent answer. Suggested temperature: #{inspect(temps)}"

      _ ->
        "#{base}Return a concise, coherent answer."
    end
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
                  "value" => %{"type" => "string"}
                },
                "required" => ["axis", "chunk", "value"],
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

  def descriptor(text, mapping, seed, chunk_count) do
    structural = structural_descriptor(text)
    affect = affect_band(text)
    abstraction = abstraction_level(mapping, text)
    seed_profile = seed_profile(mapping, seed, chunk_count)

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

  def score(candidate, reachable, frontier) do
    baseline_distance = 1.0 - maximum_similarity(candidate.answer, reachable)
    frontier_distance = 1.0 - maximum_similarity(candidate.answer, frontier)
    coverage = candidate.seed_coverage
    coherence = candidate.coherence

    overall =
      0.50 * baseline_distance +
        0.25 * frontier_distance +
        0.15 * coverage +
        0.10 * coherence

    %{
      baseline_distance: baseline_distance,
      frontier_distance: frontier_distance,
      seed_coverage: coverage,
      coherence: coherence,
      overall: Float.round(overall, 4)
    }
  end

  def similarity(a, b), do: jaccard_similarity(a, b)

  def maximum_similarity(_text, []), do: 0.0

  def maximum_similarity(text, bursts) when is_list(bursts) do
    Enum.map(bursts, fn
      %AntiAgents.BurstResult{answer: answer} -> jaccard_similarity(answer, text)
      %{answer: answer} -> jaccard_similarity(answer, text)
    end)
    |> Enum.max(fn -> 0.0 end)
  end

  def near_duplicate?(text, bursts, threshold \\ 0.91) do
    maximum_similarity(text, bursts) > threshold
  end

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
    poor_coverage? = cov.chunk_count < max(2, div(chunk_count, 3))
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

  defp jaccard_similarity(a, b) when is_binary(a) and is_binary(b) do
    a_tokens = token_set(a) |> MapSet.new()
    b_tokens = token_set(b) |> MapSet.new()

    union = MapSet.union(a_tokens, b_tokens) |> MapSet.size()
    intersection = MapSet.intersection(a_tokens, b_tokens) |> MapSet.size()

    if union == 0 do
      0.0
    else
      intersection / union
    end
  end

  defp novelty_cell(structural, affect, abstraction, seed_profile) do
    %{
      length: length_bucket(structural.length),
      sentence_count: sentence_bucket(structural.sentence_count),
      affect: affect,
      abstraction: abstraction,
      coverage: coverage_bucket(seed_profile.scope)
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

  defp coverage_bucket(value) when value < 0.34, do: :low
  defp coverage_bucket(value) when value < 0.67, do: :mid
  defp coverage_bucket(_value), do: :high

  defp count_words(text), do: token_set(text) |> length()
  defp sentence_count(text), do: String.split(text, ~r/[.!?]+/, trim: true) |> length()
  defp token_set(text), do: String.downcase(text) |> String.split(~r/[^[:alnum:]]+/, trim: true)

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

  defp abstraction_level(mapping, text) when is_map(mapping) do
    axis_count = map_size(mapping)

    cond do
      axis_count >= 6 && String.length(text) > 140 -> :high
      axis_count >= 4 -> :mid
      true -> :low
    end
  end

  defp abstraction_level(_mapping, text) do
    if String.length(text) > 180, do: :mid, else: :low
  end

  defp seed_profile(mapping, seed, chunk_count) do
    coverage = seed_coverage(mapping, chunk_count)
    chunk_count_map = parse_mapping_coverage(mapping).chunk_count

    %{
      style: "local_rolling_hash",
      scope: coverage,
      chunk_count: chunk_count_map,
      chunk_total: chunk_count,
      random_string_length: byte_size(seed),
      mode: "global_and_local"
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

  alias AntiAgents.{BurstResult, CodexClient, Field, Prompt, Scoring}

  @type burst_output :: BurstResult.t()

  @spec burst(Field.t(), keyword()) :: burst_output()
  def burst(%Field{} = field, opts \\ []) do
    options = default_burst_options(opts)
    client = Keyword.get(options, :client, CodexClient)
    seed = get_seed(options)
    chunk_size = get_coordinate(options, :chunk, 5)

    prompt = Prompt.burst_prompt(field, options)
    input = Prompt.field_input(field, options)

    case client.complete(prompt, completion_opts(field, prompt, input, options)) do
      {:ok, raw} ->
        burst_from_raw(field, seed, chunk_size, raw)

      {:error, reason} ->
        provider_error_burst(field, seed, reason)
    end
  end

  @spec branch(Field.t(), pos_integer(), keyword()) :: [burst_output()]
  def branch(%Field{} = field, n, opts) when is_integer(n) and n > 0 do
    options = default_burst_options(opts)
    concurrency = Keyword.get(options, :concurrency, System.schedulers_online())
    timeout = Keyword.get(options, :timeout_ms, 120_000)
    burst_opts = Keyword.delete(options, :seed)

    1..n
    |> Task.async_stream(fn _ -> burst(field, burst_opts) end,
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
        structured_burst(field, seed, chunk_count, text, parsed)

      {:error, reason} ->
        chunk_count = chunk_count(seed, chunk_size)
        unstructured_burst(field, seed, chunk_count, text, reason)
    end
  end

  defp structured_burst(field, seed, chunk_count, text, parsed) do
    mapping = Map.get(parsed, :mapping, %{})

    base =
      %BurstResult{
        field: field,
        seed: seed,
        random_string: parsed.random_string,
        mapping_trace: mapping,
        answer: parsed.answer,
        raw_output: text,
        status: :accepted,
        rejection_reason: nil
      }
      |> Map.put(:seed_coverage, Scoring.seed_coverage(mapping, chunk_count))

    descriptor = Scoring.descriptor(base.answer, mapping, base.random_string, chunk_count)
    candidate = Scoring.enrich(base, descriptor, base.seed_coverage)

    maybe_reject_candidate(candidate, mapping, chunk_count)
  end

  defp maybe_reject_candidate(candidate, mapping, chunk_count) do
    if Scoring.anti_collapse_fail?(mapping, chunk_count) do
      %{candidate | status: :rejected, rejection_reason: "low seed coverage / chunk collapse"}
    else
      candidate
    end
  end

  defp unstructured_burst(field, seed, chunk_count, text, reason) do
    trimmed = String.trim(text)

    if trimmed == "" do
      parse_error_burst(field, seed, reason)
    else
      synthesized_burst(field, seed, chunk_count, trimmed)
    end
  end

  defp synthesized_burst(field, seed, chunk_count, text) do
    mapping = Scoring.synthesize_mapping(text, field.axes, seed, chunk_count)
    descriptor = Scoring.descriptor(text, mapping, seed, chunk_count)

    base =
      %BurstResult{
        field: field,
        seed: seed,
        random_string: seed,
        mapping_trace: mapping,
        answer: text,
        raw_output: text,
        status: :accepted,
        rejection_reason: "unstructured model output; synthesized mapping from plain answer"
      }
      |> Map.put(:seed_coverage, Scoring.seed_coverage(mapping, chunk_count))

    Scoring.enrich(base, descriptor, base.seed_coverage)
  end

  defp parse_error_burst(field, seed, reason) do
    %BurstResult{
      field: field,
      seed: seed,
      random_string: "",
      mapping_trace: %{},
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
      answer: "",
      raw_output: "",
      status: :provider_error,
      rejection_reason: inspect(reason)
    }
  end

  defp default_burst_options(opts) do
    defaults = [
      heat: [seed: 1.3, assembly: 1.15, answer: 1.05],
      coordinate: [length: 32, chunk: 5, mapping: :local_rolling_hash],
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

  alias AntiAgents.{BurstResult, Bursts, Field, FrontierReport, Prompt, Scoring}

  @type compare_output :: %{
          field: Field.t(),
          reachable_archive: [BurstResult.t()],
          frontier_archive: [BurstResult.t()],
          delta_frontier: float(),
          reachable_hits: [map()],
          duplicates: [BurstResult.t()]
        }

  def compare(%Field{} = field, opts \\ []) do
    branch_count = Keyword.get(opts, :branching, 8)

    baseline_opts =
      Keyword.get(opts, :baseline, [
        :plain,
        :paraphrase,
        {:temperature, [0.8, 1.0, 1.2]},
        :seed_injection
      ])

    reachable = baseline_bursts(field, baseline_opts, opts)
    frontier_bursts = Bursts.branch(field, branch_count, opts)

    %{
      field: field,
      reachable_archive: reachable,
      frontier_archive: frontier_bursts,
      delta_frontier: delta_cell_count(frontier_bursts, reachable),
      reachable_hits: reachable_intersections(frontier_bursts, reachable),
      duplicates: duplicates(frontier_bursts)
    }
  end

  def frontier(%Field{} = field, opts \\ []) do
    report = compare(field, opts)

    {accepted, rejected_duplicates} =
      partition_frontier(report.frontier_archive, report.reachable_archive)

    accepted = Enum.reverse(accepted) |> score_frontier(report.reachable_archive)
    rejected_duplicates = Enum.reverse(rejected_duplicates)

    frontier_cells =
      accepted
      |> Enum.map(& &1.descriptor.cell)
      |> Enum.uniq()

    reachable_hits = reachable_hits(accepted, report.reachable_archive)

    reachable_cell_count = distinct_cell_count(report.reachable_archive)
    archive_size = length(report.frontier_archive)

    delta = length(frontier_cells) - reachable_cell_count

    %FrontierReport{
      field: field,
      exemplars: accepted,
      delta_frontier: Float.round(delta * 1.0, 3),
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
  end

  defp baseline_bursts(field, methods, opts) do
    methods
    |> Enum.flat_map(&expand_method/1)
    |> Enum.map(&baseline_burst(field, &1, opts))
    |> Enum.reject(&is_nil/1)
  end

  defp expand_method(:plain), do: [:plain]
  defp expand_method(:paraphrase), do: [:paraphrase]
  defp expand_method(:seed_injection), do: [:seed_injection]

  defp expand_method({:temperature, temps}) when is_list(temps),
    do: Enum.map(temps, &{:temperature, &1})

  defp expand_method(_), do: []

  defp baseline_burst(field, method, opts) do
    client = Keyword.get(opts, :client, AntiAgents.CodexClient)
    method_opts = baseline_method_opts(method, opts)
    prompt = Prompt.baseline_prompt(field, method, method_opts)
    input = Prompt.field_input(field, method_opts)

    case client.complete(prompt, completion_opts(field, prompt, input, method_opts)) do
      {:ok, raw} ->
        build_baseline_burst(field, method, raw)

      {:error, _reason} ->
        nil
    end
  end

  defp baseline_method_opts({:temperature, temp}, opts) when is_number(temp) do
    Keyword.put(opts, :model_settings, model_settings_with_temperature(opts, temp))
  end

  defp baseline_method_opts(_method, opts), do: opts

  defp build_baseline_burst(field, method, raw) do
    {:ok, answer} = Scoring.extract_text(raw)
    answer = String.trim(answer)

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
    }
  end

  defp score_frontier(accepted, reachable) do
    Enum.map(accepted, fn burst ->
      peers = Enum.reject(accepted, &(&1 == burst))
      Map.put(burst, :score, Scoring.score(burst, reachable, peers))
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

  defp frontier_cell_hit?(_burst, []), do: false

  defp frontier_cell_hit?(burst, reachable) do
    Enum.any?(reachable, fn base -> base.descriptor.cell == burst.descriptor.cell end)
  end

  defp partition_frontier(frontier_archive, reachable_archive) do
    Enum.reduce(frontier_archive, {[], []}, fn burst, {accepted, rejected} ->
      case accept_frontier_burst?(burst, accepted, reachable_archive) do
        true -> {[burst | accepted], rejected}
        false -> {accepted, [burst | rejected]}
      end
    end)
  end

  defp accept_frontier_burst?(%{status: :accepted} = burst, accepted, reachable_archive) do
    not Scoring.duplicate?(burst, accepted) and
      not frontier_cell_hit?(burst, reachable_archive)
  end

  defp accept_frontier_burst?(_burst, _accepted, _reachable_archive), do: false

  defp reachable_intersections(frontier, reachable) do
    Enum.flat_map(frontier, fn burst ->
      if has_descriptor?(burst) and frontier_cell_hit?(burst, reachable) do
        [%{burst: burst, reason: "reachable"}]
      else
        []
      end
    end)
  end

  defp delta_cell_count(frontier, reachable) do
    frontier_cells =
      frontier
      |> Enum.filter(&has_descriptor?/1)
      |> Enum.map(& &1.descriptor.cell)
      |> Enum.uniq()
      |> length()

    reachable_cells =
      reachable
      |> Enum.filter(&has_descriptor?/1)
      |> Enum.map(& &1.descriptor.cell)
      |> Enum.uniq()
      |> length()

    frontier_cells - reachable_cells
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
