defmodule AntiAgentsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AntiAgents.{BurstResult, Field, FrontierReport}
  alias AntiAgents.{Bursts, Progress, Scoring}
  alias Mix.Tasks.AntiAgents.Frontier, as: FrontierTask

  defmodule FakeOptions do
    def new(opts) do
      send(self(), {:codex_opts, opts})
      {:ok, %{codex_opts: opts}}
    end
  end

  defmodule FakeThreadOptions do
    def new(opts), do: {:ok, %{thread_opts: opts}}
  end

  defmodule FakeAgent do
    def new(attrs) do
      send(self(), {:agent_attrs, attrs})
      {:ok, %{agent: attrs}}
    end
  end

  defmodule FakeRunConfig do
    def new(attrs) do
      send(self(), {:run_config_attrs, attrs})
      {:ok, %{run_config: attrs}}
    end
  end

  defmodule FakeCodex do
    def start_thread(codex_opts, thread_opts) do
      send(self(), {:start_thread, codex_opts, thread_opts})
      {:ok, %{thread: true}}
    end
  end

  defmodule FakeRunner do
    def run(thread, input, opts) do
      send(self(), {:runner_call, thread, input, opts})
      {:ok, %{final_response: "ok"}}
    end
  end

  defmodule BurstClient do
    def complete(_prompt, opts) do
      send(self(), {:burst_opts, opts})

      {:ok,
       AntiAgentsTest.valid_burst_json(
         "seed-model-value",
         "A coherent and novel reply with multiple local decisions.",
         axes: ["ontology", "metaphor", "closure"],
         chunks: [0, 1, 2],
         chunk_size: 4
       )}
    end
  end

  defmodule PrefixRejectClient do
    def complete(_prompt, _opts) do
      {:ok,
       AntiAgentsTest.valid_burst_json("seed-value", "Looks okay.",
         axes: ["ontology", "syntax"],
         chunks: [0, 0],
         chunk_size: 4
       )}
    end
  end

  defmodule PlainClient do
    def complete(_prompt, _opts), do: {:ok, "A plain answer without structure."}
  end

  defmodule ArtifactClient do
    def complete(_prompt, _opts) do
      nested_answer =
        Jason.encode!(%{
          "schema_version" => "1",
          "mode" => "dry_run",
          "run_config" => %{},
          "exemplars" => []
        })

      {:ok,
       AntiAgentsTest.valid_burst_json("artifact-model-seed", nested_answer,
         axes: ["ontology", "metaphor", "closure"],
         chunks: [0, 1, 2],
         chunk_size: 4
       )}
    end
  end

  defmodule PromptEchoClient do
    def complete(_prompt, _opts) do
      {:ok,
       AntiAgentsTest.valid_burst_json(
         "echo-model-seed",
         "Coordinate nonce: echo-seed Field prompt: leaked prompt text",
         axes: ["ontology", "metaphor", "closure"],
         chunks: [0, 1, 2],
         chunk_size: 4
       )}
    end
  end

  defmodule ContractClient do
    def complete(prompt, opts) do
      send(opts[:test_pid], {:client_call, prompt, opts})

      if String.contains?(prompt, "Produce exactly one exploration") do
        {:ok,
         AntiAgentsTest.valid_burst_json("contract-model-seed", "Frontier answer text.",
           axes: ["ontology", "metaphor", "closure"],
           chunks: [0, 1, 2],
           chunk_size: 4
         )}
      else
        {:ok, "Plain reachable baseline answer."}
      end
    end
  end

  defmodule SlowBaselineClient do
    def complete(prompt, opts) do
      send(opts[:test_pid], {:slow_client_call, prompt, System.monotonic_time(:millisecond)})

      if String.contains?(prompt, "Produce exactly one exploration") do
        {:ok,
         AntiAgentsTest.valid_burst_json("slow-model-seed", "Frontier answer text.",
           axes: ["ontology", "metaphor"],
           chunks: [0, 1],
           chunk_size: 5
         )}
      else
        Process.sleep(120)
        {:ok, "Slow baseline answer."}
      end
    end
  end

  defmodule FrontierClient do
    def complete(prompt, _opts) do
      if String.contains?(prompt, "Produce exactly one exploration") do
        {:ok,
         AntiAgentsTest.valid_burst_json(
           "frontier-model-seed",
           "Novel frontier output with different framing and metaphor.",
           axes: ["ontology", "metaphor", "closure"],
           chunks: [0, 1, 2],
           chunk_size: 3
         )}
      else
        {:ok, "baseline response"}
      end
    end
  end

  defmodule InvalidHashClient do
    def complete(_prompt, _opts) do
      payload =
        "hash-model-seed"
        |> AntiAgentsTest.valid_burst_map("Hash-invalid answer.",
          axes: ["ontology", "metaphor", "closure"],
          chunks: [0, 1, 2],
          chunk_size: 4
        )
        |> put_in(["mapping", "decisions", Access.at(1), "hash"], 999_999)

      {:ok, Jason.encode!(payload)}
    end
  end

  defmodule NonceCopyClient do
    def complete(_prompt, _opts) do
      {:ok,
       AntiAgentsTest.valid_burst_json("host-nonce", "Nonce-copy answer.",
         axes: ["ontology", "metaphor", "closure"],
         chunks: [0, 1, 2],
         chunk_size: 4
       )}
    end
  end

  defmodule InvalidChunkClient do
    def complete(_prompt, _opts) do
      {:ok,
       AntiAgentsTest.valid_burst_json("chunk-model-seed", "Invalid-chunk answer.",
         axes: ["ontology", "metaphor", "closure"],
         chunks: [0, 1, 99],
         chunk_size: 4
       )}
    end
  end

  defmodule ShortRandomClient do
    def complete(_prompt, _opts) do
      {:ok,
       AntiAgentsTest.valid_burst_json("abc", "Short-random answer.",
         axes: ["ontology", "metaphor"],
         chunks: [0, 0],
         chunk_size: 3
       )}
    end
  end

  defmodule RepetitiveRandomClient do
    def complete(_prompt, _opts) do
      {:ok,
       AntiAgentsTest.valid_burst_json("aaaaaaaaaaaa", "Repetitive-random answer.",
         axes: ["ontology", "metaphor", "closure"],
         chunks: [0, 1, 2],
         chunk_size: 4
       )}
    end
  end

  defmodule PatternRandomClient do
    def complete(_prompt, _opts) do
      {:ok,
       AntiAgentsTest.valid_burst_json("aaaaabbbbbcccccddddd", "Pattern-random answer.",
         axes: ["ontology", "metaphor", "closure"],
         chunks: [0, 1, 2],
         chunk_size: 5
       )}
    end
  end

  defmodule QueueClient do
    def complete(prompt, opts) do
      response =
        Agent.get_and_update(opts[:queue], fn
          [next | rest] -> {next, rest}
          [] -> raise "QueueClient exhausted for prompt: #{prompt}"
        end)

      {:ok, response}
    end
  end

  describe "field/2" do
    test "normalizes axes and captures steering text" do
      field =
        AntiAgents.field("seeded memory",
          axes: [:syntax, "affect"],
          toward: ["a", "b"],
          away_from: ["c"]
        )

      assert %Field{} = field
      assert field.prompt == "seeded memory"
      assert :syntax in field.axes
      assert :affect in field.axes
      assert field.toward == ["a", "b"]
      assert field.away_from == ["c"]
    end
  end

  describe "burst/2" do
    test "returns explicit structured result and threads temperature through settings" do
      field = AntiAgents.field("the memory of a color that doesn't exist")
      test_pid = self()

      burst =
        Bursts.burst(field,
          client: BurstClient,
          client_opts: [],
          progress_callback: fn event, meta -> send(test_pid, {:progress, event, meta}) end,
          heat: [answer: 1.0],
          thinking_budget: 900,
          seed: "seed-value",
          coordinate: [length: 12, chunk: 4]
        )

      assert_receive {:burst_opts, opts}
      assert_in_delta opts[:model_settings].temperature, 1.0, 0.0001
      assert opts[:model_settings].max_tokens == 900
      assert opts[:model] == "gpt-5.4-mini"
      assert opts[:reasoning_effort] == :low
      assert String.contains?(opts[:input], "Coordinate nonce: seed-value")
      assert_receive {:progress, :burst_call_start, %{temperature: 1.0}}
      assert_receive {:progress, :burst_call_done, %{status: :accepted}}

      assert %BurstResult{} = burst
      assert burst.status == :accepted
      assert burst.random_string == "seed-model-value"
      assert burst.mapping_trace["decisions"] |> length() == 3
      assert burst.answer == "A coherent and novel reply with multiple local decisions."
      assert burst.seed_coverage > 0.0
      assert burst.mapping_verification.valid? == true
    end

    test "rejects low-coverage prefix-only mapping" do
      field = AntiAgents.field("minimal", axes: [:ontology, :syntax])

      burst =
        Bursts.burst(field,
          client: PrefixRejectClient,
          client_opts: [],
          seed: "aaaaaaaaaaaaaaaa",
          coordinate: [length: 16, chunk: 4]
        )

      assert burst.status == :rejected
      assert burst.rejection_reason =~ "low seed coverage"
    end

    test "rejects unstructured plain burst output instead of accepting synthesized SSoT evidence" do
      field = AntiAgents.field("fallback", axes: [:ontology, :metaphor, :syntax])

      burst =
        Bursts.burst(field,
          client: PlainClient,
          client_opts: [],
          seed: "plain-seed",
          coordinate: [length: 12, chunk: 4]
        )

      assert burst.status == :parse_error
      assert burst.answer == "A plain answer without structure."
      assert burst.rejection_reason =~ "unstructured"
      assert burst.mapping_trace == %{}
    end

    test "rejects invalid host-verifiable mapping hashes" do
      field = AntiAgents.field("invalid hash", axes: [:ontology, :metaphor, :closure])

      burst =
        Bursts.burst(field,
          client: InvalidHashClient,
          client_opts: [],
          seed: "host-seed",
          coordinate: [length: 12, chunk: 4]
        )

      assert burst.status == :rejected
      assert burst.rejection_reason =~ "invalid mapping"
      assert burst.mapping_verification.valid? == false
    end

    test "rejects invalid mapping chunk indexes" do
      field = AntiAgents.field("invalid chunk", axes: [:ontology, :metaphor, :closure])

      burst =
        Bursts.burst(field,
          client: InvalidChunkClient,
          client_opts: [],
          seed: "host-seed",
          coordinate: [length: 12, chunk: 4]
        )

      assert burst.status == :rejected
      assert burst.rejection_reason =~ "invalid_chunk"
    end

    test "rejects model random strings that copy the host coordinate nonce" do
      field = AntiAgents.field("nonce copy", axes: [:ontology, :metaphor, :closure])

      burst =
        Bursts.burst(field,
          client: NonceCopyClient,
          client_opts: [],
          seed: "host-nonce",
          coordinate: [length: 12, chunk: 4]
        )

      assert burst.status == :rejected
      assert burst.rejection_reason =~ "random string copied coordinate nonce"
    end

    test "rejects short and repetitive model random strings" do
      field = AntiAgents.field("bad random", axes: [:ontology, :metaphor, :closure])

      short =
        Bursts.burst(field,
          client: ShortRandomClient,
          client_opts: [],
          seed: "host-seed",
          coordinate: [length: 12, chunk: 3]
        )

      repetitive =
        Bursts.burst(field,
          client: RepetitiveRandomClient,
          client_opts: [],
          seed: "host-seed",
          coordinate: [length: 12, chunk: 4]
        )

      patterned =
        Bursts.burst(field,
          client: PatternRandomClient,
          client_opts: [],
          seed: "host-seed",
          coordinate: [length: 20, chunk: 5]
        )

      assert short.status == :rejected
      assert short.rejection_reason =~ "too short"
      assert repetitive.status == :rejected
      assert repetitive.rejection_reason =~ "too repetitive"
      assert patterned.status == :rejected
      assert patterned.rejection_reason =~ "too repetitive"
    end

    test "rejects nested control payloads instead of accepting them as answers" do
      field = AntiAgents.field("artifact guard", axes: [:ontology, :metaphor, :closure])

      burst =
        Bursts.burst(field,
          client: ArtifactClient,
          client_opts: [],
          seed: "artifact-seed",
          coordinate: [length: 12, chunk: 4]
        )

      assert burst.status == :rejected
      assert burst.rejection_reason =~ "artifact answer"
    end

    test "rejects prompt echoes instead of accepting them as answers" do
      field = AntiAgents.field("prompt echo guard", axes: [:ontology, :metaphor, :closure])

      burst =
        Bursts.burst(field,
          client: PromptEchoClient,
          client_opts: [],
          seed: "echo-seed",
          coordinate: [length: 12, chunk: 4]
        )

      assert burst.status == :rejected
      assert burst.rejection_reason =~ "artifact answer"
    end
  end

  describe "codex sdk integration" do
    test "builds a live Codex payload for gpt-5.4-mini low with turn temperature evidence" do
      assert {:ok, "ok"} =
               AntiAgents.CodexClient.complete("prompt",
                 input: "input",
                 heat: [answer: 1.23],
                 thinking_budget: 777,
                 output_schema: %{"type" => "object"},
                 options_module: FakeOptions,
                 thread_options_module: FakeThreadOptions,
                 agent_module: FakeAgent,
                 run_config_module: FakeRunConfig,
                 codex_module: FakeCodex,
                 agent_runner_module: FakeRunner
               )

      assert_receive {:codex_opts, codex_opts}
      assert payload = Keyword.fetch!(codex_opts, :model_payload)
      assert payload.resolved_model == "gpt-5.4-mini"
      assert payload.reasoning == "low"
      refute Keyword.has_key?(codex_opts, :model)
      refute Keyword.has_key?(codex_opts, :reasoning_effort)

      assert_receive {:runner_call, %{thread: true}, "input", runner_opts}
      assert runner_opts.turn_opts.output_schema == %{"type" => "object"}
      assert {"temperature", 1.23} in runner_opts.turn_opts.config_overrides

      assert_receive {:run_config_attrs, run_config_attrs}
      refute Map.has_key?(run_config_attrs, :model)
      assert run_config_attrs.model_settings.temperature == 1.23
    end
  end

  describe "branch/2" do
    test "runs multiple bursts in parallel from the same field" do
      field = AntiAgents.field("branching demo", axes: [:ontology, :metaphor])

      bursts =
        AntiAgents.branch(field, 3,
          client: BurstClient,
          client_opts: [],
          heat: [answer: 1.0],
          thinking_budget: 700,
          coordinate: [length: 12, chunk: 4]
        )

      assert length(bursts) == 3
      assert Enum.all?(bursts, &match?(%BurstResult{}, &1))
    end
  end

  describe "compare/2 and frontier/2" do
    test "frontier report has explicit fields" do
      field = AntiAgents.field("field for frontier", axes: [:ontology, :metaphor])

      opts = [
        client: FrontierClient,
        branching: 3,
        baseline: [:plain],
        heat: [answer: 1.0],
        coordinate: [length: 12, chunk: 3]
      ]

      report = AntiAgents.frontier(field, opts)
      assert %FrontierReport{} = report
      assert report.field == field
      assert is_list(report.exemplars)
      assert is_list(report.reachable_archive)
      assert is_list(report.mapping_traces)
      assert is_integer(report.frontier_cell_count)
      assert is_integer(report.reachable_cell_count)
      assert is_integer(report.novel_frontier_cell_count)
      assert is_number(report.coverage_delta)
      assert Map.has_key?(report.metrics, :distinct)
      assert Map.has_key?(report.metrics, :archive_coverage)
    end

    test "compare returns reachable and frontier archives" do
      field = AntiAgents.field("field for compare")

      compare =
        AntiAgents.compare(
          field,
          baseline: [:plain],
          branching: 2,
          client: FrontierClient,
          heat: [answer: 1.0]
        )

      assert compare.field == field
      assert is_list(compare.reachable_archive)
      assert is_list(compare.frontier_archive)
      assert is_integer(compare.novel_frontier_cell_count)
    end

    test "descriptor cells do not treat seed coverage as frontier novelty" do
      answer = "Same observable answer for both archive sides."

      baseline_cell =
        Scoring.descriptor(answer, %{}, "", 1).cell

      mapping =
        "abcdef123456"
        |> AntiAgentsTest.valid_burst_map(answer,
          axes: ["ontology", "metaphor", "closure"],
          chunks: [0, 1, 2],
          chunk_size: 4
        )
        |> get_in(["mapping"])

      ssot_cell = Scoring.descriptor(answer, mapping, "abcdef123456", 3).cell

      assert baseline_cell == ssot_cell
    end

    test "frontier metrics use set difference against reachable cells" do
      {:ok, queue} =
        Agent.start_link(fn ->
          [
            "A short reachable answer.",
            AntiAgentsTest.valid_burst_json("same-cell-model-seed", "A short reachable answer.",
              axes: ["ontology", "metaphor", "closure"],
              chunks: [0, 1, 2],
              chunk_size: 4
            ),
            AntiAgentsTest.valid_burst_json(
              "novel-frontier-seed",
              "A longer frontier answer that uses multiple sentences. It should occupy a different descriptor cell.",
              axes: ["ontology", "metaphor", "closure"],
              chunks: [0, 1, 2],
              chunk_size: 4
            )
          ]
        end)

      field = AntiAgents.field("set difference", axes: [:ontology, :metaphor, :closure])

      report =
        AntiAgents.frontier(field,
          baseline: [:plain],
          branching: 2,
          client: QueueClient,
          client_opts: [queue: queue],
          concurrency: 1,
          coordinate: [length: 16, chunk: 4]
        )

      assert report.reachable_cell_count == 1
      assert report.frontier_cell_count == 1
      assert report.novel_frontier_cell_count == 1
      assert length(report.exemplars) == 1
      assert length(report.rejected_duplicates) == 1
      assert hd(report.rejected_duplicates).rejection_reason =~ "reachable"
    end

    test "duplicate model random strings are rejected within a frontier run" do
      {:ok, queue} =
        Agent.start_link(fn ->
          [
            "Baseline answer.",
            AntiAgentsTest.valid_burst_json(
              "duplicate-model-seed",
              "First frontier answer with enough length to occupy a longer cell. It has a second sentence.",
              axes: ["ontology", "metaphor", "closure"],
              chunks: [0, 1, 2],
              chunk_size: 4
            ),
            AntiAgentsTest.valid_burst_json(
              "duplicate-model-seed",
              "Second frontier answer using the same model random string but different wording. It also has a second sentence.",
              axes: ["ontology", "metaphor", "closure"],
              chunks: [0, 1, 2],
              chunk_size: 4
            )
          ]
        end)

      field = AntiAgents.field("duplicate random", axes: [:ontology, :metaphor, :closure])

      report =
        AntiAgents.frontier(field,
          baseline: [:plain],
          branching: 2,
          client: QueueClient,
          client_opts: [queue: queue],
          concurrency: 1,
          coordinate: [length: 16, chunk: 4]
        )

      assert report.duplicate_random_string_count == 1

      assert Enum.any?(
               report.rejected_duplicates,
               &(&1.rejection_reason =~ "duplicate random_string")
             )
    end

    test "baseline calls use a clean non-SSoT contract except explicit seed injection" do
      field = AntiAgents.field("field for clean baselines")

      AntiAgents.compare(field,
        baseline: [:plain, :paraphrase, {:temperature, [1.0]}, :seed_injection],
        branching: 1,
        client: ContractClient,
        client_opts: [test_pid: self()],
        seed: "fixed-seed",
        concurrency: 4,
        heat: [answer: 1.0]
      )

      calls = collect_client_calls(5)

      baseline_calls =
        Enum.reject(calls, fn {prompt, _opts} ->
          String.contains?(prompt, "Produce exactly one exploration")
        end)

      burst_calls =
        Enum.filter(calls, fn {prompt, _opts} ->
          String.contains?(prompt, "Produce exactly one exploration")
        end)

      assert length(baseline_calls) == 4
      assert length(burst_calls) == 1

      Enum.each(baseline_calls, fn {prompt, opts} ->
        refute Keyword.has_key?(opts, :output_schema)
        assert String.contains?(prompt, "Return only the generated answer text itself")
        refute String.contains?(opts[:input], "Coordinate nonce:")
      end)

      seed_injection =
        Enum.find(baseline_calls, fn {_prompt, opts} ->
          String.contains?(opts[:input], "Baseline method: seed_injection")
        end)

      assert {_prompt, seed_opts} = seed_injection
      assert String.contains?(seed_opts[:input], "Seed: fixed-seed")
    end

    test "baseline calls are parallelized independently from frontier bursts" do
      test_pid = self()
      field = AntiAgents.field("parallel baselines")

      AntiAgents.compare(field,
        baseline: [:plain, :paraphrase, {:temperature, [1.0]}],
        branching: 1,
        client: SlowBaselineClient,
        client_opts: [test_pid: test_pid],
        concurrency: 3,
        heat: [answer: 1.0]
      )

      baseline_starts =
        4
        |> collect_slow_client_calls()
        |> Enum.reject(fn {prompt, _at} ->
          String.contains?(prompt, "Produce exactly one exploration")
        end)
        |> Enum.map(fn {_prompt, at} -> at end)

      assert length(baseline_starts) == 3
      assert Enum.max(baseline_starts) - Enum.min(baseline_starts) < 80
    end
  end

  describe "parse and score" do
    test "parses burst contract tags and scoring keys" do
      output = """
      <random_string>abc</random_string>
      <mapping>{"decisions":[{"axis":"ontology","chunk":0,"hash":#{Scoring.local_hash("ontology", "abc", 0)},"choice":0,"value":"x"}]}</mapping>
      <answer>One two three four five six seven eight.</answer>
      """

      assert {:ok, parsed} = Scoring.parse_burst_output(output)
      assert parsed.random_string == "abc"
      assert parsed.mapping["decisions"] |> length() == 1

      verification = Scoring.verify_mapping(parsed.mapping, parsed.random_string, 3)
      assert verification.valid? == true
      assert verification.coverage == 1.0
    end

    test "caps seed coverage at one when mappings over-report chunks" do
      mapping = %{
        "decisions" =>
          Enum.map(0..5, fn chunk -> %{"axis" => "axis", "chunk" => chunk, "value" => "x"} end)
      }

      assert Scoring.seed_coverage(mapping, 3) == 1.0
    end

    test "verified mapping rejects missing or incorrect hash evidence" do
      mapping = %{"decisions" => [%{"axis" => "ontology", "chunk" => 0, "value" => "x"}]}
      verification = Scoring.verify_mapping(mapping, "abcdef", 3)

      assert verification.valid? == false
      assert "missing_hash" in verification.invalid_reasons
    end

    test "extracts text from supported provider result shapes" do
      assert Scoring.extract_text(%{content: "content"}) == {:ok, "content"}
      assert Scoring.extract_text(%{"content" => "content"}) == {:ok, "content"}
      assert Scoring.extract_text(%{text: "text"}) == {:ok, "text"}
      assert Scoring.extract_text(%{message: %{content: "message"}}) == {:ok, "message"}
      assert Scoring.extract_text(%{other: true}) == {:ok, "%{other: true}"}
    end

    test "reports parse errors for malformed structured output" do
      assert {:error, {:bad_mapping_json, _}} =
               Scoring.parse_burst_output("""
               <random_string>abcdef123</random_string>
               <mapping>{bad</mapping>
               <answer>Answer.</answer>
               """)

      assert {:error, {:missing_tag, "mapping"}} =
               Scoring.parse_burst_output("""
               <random_string>abcdef123</random_string>
               <answer>Answer.</answer>
               """)

      assert {:error, :invalid_output} = Scoring.parse_burst_output(%{})
    end

    test "scores distance, duplicate detection, coherence, and descriptors" do
      field = AntiAgents.field("score field")

      base = %BurstResult{
        field: field,
        answer: "calm clarity resonance",
        status: :accepted,
        descriptor: %{},
        seed_coverage: 0.0,
        coherence: 0.3
      }

      candidate = %BurstResult{
        field: field,
        answer: "violent fracture confusion in an impossible memory of language perception",
        status: :accepted,
        descriptor: %{},
        seed_coverage: 0.75,
        coherence:
          Scoring.coherence(
            "violent fracture confusion in an impossible memory of language perception"
          )
      }

      score = Scoring.score(candidate, [base], [])
      assert score.baseline_distance > 0.0
      refute Scoring.duplicate?(candidate, [base])
      assert Scoring.coherence("") == 0.0

      descriptor =
        Scoring.descriptor(
          candidate.answer,
          %{"decisions" => []},
          "abcdef123456",
          3,
          %{valid?: false, coverage: 0.0}
        )

      assert descriptor.affect in [:low, :medium, :high]
      assert descriptor.abstraction in [:mid, :high]
      assert descriptor.seed_profile.verified? == false
    end

    test "covers scoring fallbacks and synthetic audit helpers" do
      assert Scoring.similarity("one two", "two three") > 0.0
      assert Scoring.maximum_similarity("same", [%{answer: "same"}]) == 1.0
      assert Scoring.artifact_answer?(123) == false
      assert Scoring.clean_plain_answer("") == {:error, :empty_answer}
      assert Scoring.clean_plain_answer(%{}) == {:error, :invalid_answer}
      assert Scoring.parse_mapping_coverage(:bad) == %{axis_count: 0, chunk_count: 0}
      assert Scoring.anti_collapse_fail?(%{"decisions" => [%{"chunk" => 0}]}, 6)

      mapping = Scoring.synthesize_mapping("abcdefghijklmnopqrstuvwxyz", [:a, :b, :c], "seed", 3)
      assert length(mapping["decisions"]) == 3

      assert {:error, {:missing_tag, "random_string"}} =
               Scoring.parse_burst_output(~s({"ordinary":true}))

      assert {:ok, parsed} =
               Scoring.parse_burst_output(
                 Jason.encode!(%{
                   "random_string" => 123,
                   "mapping" => [],
                   "answer" => 456
                 })
               )

      assert parsed.random_string == "123"
      assert parsed.answer == "456"

      assert Scoring.descriptor(String.duplicate("long ", 80), %{}, "", 1).cell.length ==
               :extended

      assert Scoring.descriptor("One. Two. Three. Four. Five.", %{}, "", 1).cell.sentence_count ==
               :medium

      assert Scoring.descriptor("One. Two. Three. Four. Five. Six. Seven.", %{}, "", 1).cell.sentence_count ==
               :large

      assert Scoring.descriptor("growth harmony calm clarity resonance", %{}, "", 1).affect ==
               :high

      refute Scoring.artifact_answer?("")
      refute Scoring.artifact_answer?("plain ordinary answer")
    end

    test "verify_mapping reports non-map, invalid axis, and invalid chunk cases" do
      assert Scoring.verify_mapping("bad", "abcdef", 3).valid? == false

      missing_axis = %{
        "decisions" => [%{"chunk" => 0, "hash" => Scoring.local_hash("", "abc", 0)}]
      }

      assert "missing_axis" in Scoring.verify_mapping(missing_axis, "abcdef", 3).invalid_reasons

      invalid_chunk = %{
        "decisions" => [
          %{"axis" => "ontology", "chunk" => "bad", "hash" => 1, "value" => "x"}
        ]
      }

      assert "invalid_chunk" in Scoring.verify_mapping(invalid_chunk, "abcdef", 3).invalid_reasons

      invalid_decision = %{"decisions" => ["bad"]}

      assert "invalid_decision" in Scoring.verify_mapping(invalid_decision, "abcdef", 3).invalid_reasons

      string_hash = %{
        "decisions" => [
          %{
            "axis" => "ontology",
            "chunk" => "0",
            "hash" => Integer.to_string(Scoring.local_hash("ontology", "abc", 0)),
            "value" => "x"
          }
        ]
      }

      assert Scoring.verify_mapping(string_hash, "abcdef", 3).valid? == true
    end

    test "unwraps nested JSON when a structured model puts the whole burst in answer" do
      output =
        Jason.encode!(%{
          "random_string" => "outer",
          "mapping" => %{"decisions" => []},
          "answer" =>
            Jason.encode!(%{
              "random_string" => "inner",
              "mapping" => %{"decisions" => [%{"axis" => "ontology", "chunk" => 0}]},
              "answer" => "Only the final answer text."
            })
        })

      assert {:ok, parsed} = Scoring.parse_burst_output(output)
      assert parsed.random_string == "inner"
      assert parsed.mapping["decisions"] == [%{"axis" => "ontology", "chunk" => 0}]
      assert parsed.answer == "Only the final answer text."
    end

    test "unwraps malformed nested JSON when answer is embedded under mapping" do
      output =
        Jason.encode!(%{
          "random_string" => "outer",
          "mapping" => %{"decisions" => []},
          "answer" =>
            Jason.encode!(%{
              "random_string" => "inner",
              "mapping" => %{
                "decisions" => [%{"axis" => "ontology", "chunk" => 0}],
                "answer" => "Only the embedded answer text."
              }
            })
        })

      assert {:ok, parsed} = Scoring.parse_burst_output(output)
      assert parsed.random_string == "inner"
      assert parsed.mapping["decisions"] == [%{"axis" => "ontology", "chunk" => 0}]
      assert parsed.answer == "Only the embedded answer text."
    end

    test "detects anti-agents control JSON as an artifact answer" do
      answer =
        Jason.encode!(%{
          "schema_version" => "1",
          "mode" => "dry_run",
          "mapping_traces" => []
        })

      assert Scoring.artifact_answer?(answer)
      refute Scoring.artifact_answer?(~s({"ordinary":"json","payload":true}))
      assert Scoring.artifact_answer?("Coordinate nonce: abc Field prompt: leaked")
      assert Scoring.artifact_answer?(~s({"random_string":"abc","mapping":{"decisions":[))
      assert Scoring.artifact_answer?("```bash\nmix anti_agents.frontier demo\n```")
      assert Scoring.artifact_answer?("A refined version of the prompt: better words")
      assert Scoring.artifact_answer?("A refined prompt you can use: **The memory of a color**")
      assert Scoring.artifact_answer?("Use this field with empty steering lists")
    end

    test "cleans answer-only JSON and rejects nested control JSON in plain answers" do
      assert Scoring.clean_plain_answer(~s({"answer":"Plain text."})) == {:ok, "Plain text."}

      nested =
        Jason.encode!(%{
          "answer" =>
            Jason.encode!(%{
              "random_string" => "abc",
              "mapping" => %{"decisions" => []}
            })
        })

      assert Scoring.clean_plain_answer(nested) == {:error, :artifact_answer}
    end
  end

  describe "CLI and trace" do
    test "parses dry-run frontier command options for live onboarding" do
      assert {:ok, {prompt, opts}} =
               AntiAgents.CLI.parse_frontier_args([
                 "memory",
                 "field",
                 "--dry-run",
                 "--branching",
                 "12",
                 "--temperature",
                 "1.18",
                 "--model",
                 "gpt-5.4-mini",
                 "--reasoning",
                 "low",
                 "--verbose",
                 "--heartbeat-ms",
                 "250",
                 "--length",
                 "40",
                 "--chunk",
                 "4",
                 "--baseline",
                 "plain,paraphrase,temp:0.8|1.0",
                 "--toward",
                 "machine pastoral",
                 "--away-from",
                 "standard sci-fi"
               ])

      assert prompt == "memory field"
      assert opts[:dry_run] == true
      assert opts[:verbose] == true
      assert opts[:heartbeat_ms] == 250
      assert opts[:branching] == 12
      assert opts[:coordinate][:length] == 40
      assert opts[:coordinate][:chunk] == 4
      assert opts[:model] == "gpt-5.4-mini"
      assert opts[:reasoning_effort] == :low
      assert opts[:heat][:answer] == 1.18
      assert opts[:baseline] == [:plain, :paraphrase, {:temperature, [0.8, 1.0]}]
      assert opts[:field][:toward] == ["machine pastoral"]
      assert opts[:field][:away_from] == ["standard sci-fi"]
    end

    test "CLI rejects invalid options and empty prompts" do
      assert {:error, usage} = AntiAgents.CLI.parse_frontier_args(["--dry-run"])
      assert usage =~ "Usage:"

      assert {:error, invalid} = AntiAgents.CLI.parse_frontier_args(["field", "--unknown"])
      assert invalid =~ "Invalid options"
    end

    test "CLI applies default and alternate baseline forms" do
      assert {:ok, {_prompt, opts}} = AntiAgents.CLI.parse_frontier_args(["default baseline"])

      assert opts[:baseline] == [
               :plain,
               :paraphrase,
               {:temperature, [0.8, 1.0, 1.2]},
               :seed_injection
             ]

      assert {:ok, {_prompt, opts}} =
               AntiAgents.CLI.parse_frontier_args([
                 "baseline forms",
                 "--baseline",
                 "seed_injection,temperature:0.7,unknown"
               ])

      assert opts[:baseline] == [:seed_injection, {:temperature, [0.7]}]
      assert opts[:include_raw] == false
      assert opts[:timeout_ms] == 120_000
    end

    test "Codex config resolves model, reasoning, payload, and overrides" do
      opts = [
        model: "gpt-test",
        reasoning_effort: "HIGH",
        heat: [answer: 1.2],
        config_overrides: [{"foo", "bar"}]
      ]

      assert AntiAgents.CodexConfig.model(opts) == "gpt-test"
      assert AntiAgents.CodexConfig.reasoning_effort(opts) == :high
      assert {"temperature", 1.2} in AntiAgents.CodexConfig.temperature_config_overrides(opts)

      codex_opts = AntiAgents.CodexConfig.codex_opts(opts)
      assert codex_opts[:model_payload].resolved_model == "gpt-test"
      assert codex_opts[:model_payload].reasoning == "high"

      assert AntiAgents.CodexConfig.codex_opts(
               codex_opts: [model_payload: %{resolved_model: "x"}]
             ) ==
               [model_payload: %{resolved_model: "x"}]

      merged =
        AntiAgents.CodexConfig.merge_config_overrides(opts, %{config_overrides: [{"baz", 1}]})

      assert {"foo", "bar"} in merged
      assert {"baz", 1} in merged

      assert AntiAgents.CodexConfig.model(%{"model" => "map-model"}) == "map-model"
      assert AntiAgents.CodexConfig.reasoning_effort(reasoning_effort: nil) == :low
      assert AntiAgents.CodexConfig.reasoning_effort(reasoning_effort: 123) == :low

      assert AntiAgents.CodexConfig.codex_opts(
               codex_opts: %{"model" => "nested", "reasoning" => "medium"}
             )[:model_payload].resolved_model == "nested"

      assert AntiAgents.CodexConfig.model(model: "", codex_opts: [model: "fallback-model"]) ==
               "fallback-model"

      assert AntiAgents.CodexConfig.model(:bad) == "gpt-5.4-mini"
    end

    test "mix frontier dry-run prints JSON without live model calls" do
      Mix.Task.reenable("anti_agents.frontier")

      output =
        capture_io(fn ->
          FrontierTask.run([
            "dry",
            "field",
            "--dry-run",
            "--branching",
            "2",
            "--baseline",
            "plain,temp:0.8",
            "--model",
            "gpt-5.4-mini",
            "--reasoning",
            "low"
          ])
        end)

      assert output =~ "\"mode\": \"dry_run\""
      assert output =~ "\"prompt\": \"dry field\""
      assert output =~ "\"branching\": 2"
    end

    test "mix frontier dry-run writes trace to --out path" do
      Mix.Task.reenable("anti_agents.frontier")
      path = "tmp/test_dry_run_trace.json"
      File.rm(path)

      output =
        capture_io(fn ->
          FrontierTask.run([
            "dry",
            "out",
            "--dry-run",
            "--branching",
            "1",
            "--baseline",
            "plain",
            "--out",
            path
          ])
        end)

      assert output =~ "Wrote AntiAgents trace to #{path}"
      assert File.exists?(path)
      assert {:ok, trace} = path |> File.read!() |> Jason.decode()
      assert trace["mode"] == "dry_run"
      assert trace["field"]["prompt"] == "dry out"
    after
      File.rm("tmp/test_dry_run_trace.json")
    end

    test "heartbeat progress can be observed during long live runs" do
      test_pid = self()

      result =
        Progress.with_heartbeat(
          [
            heartbeat_ms: 10,
            progress_callback: fn event, meta -> send(test_pid, {:progress, event, meta}) end
          ],
          :test_run,
          fn ->
            Process.sleep(25)
            :ok
          end
        )

      assert result == :ok
      assert_receive {:progress, :heartbeat, %{label: :test_run, tick: 1}}
    end

    test "verbose progress explains the run plan, stage purpose, and previews" do
      output =
        capture_io(:stderr, fn ->
          Progress.with_heartbeat(
            [verbose: true, heartbeat_ms: 50, preview_chars: 60],
            :test_run,
            fn opts ->
              Progress.event(opts, :run_plan, %{
                baseline_calls: 2,
                frontier_bursts: 3,
                total_llm_calls: 5,
                concurrency: 2
              })

              Progress.event(opts, :baseline_start, %{methods: 2})

              Progress.event(opts, :baseline_call_start, %{
                index: 1,
                total: 2,
                llm_index: 1,
                llm_total: 5,
                method: "plain",
                input_preview: "Field prompt with enough detail to preview in logs"
              })

              Progress.event(opts, :baseline_call_done, %{
                index: 1,
                total: 2,
                llm_index: 1,
                llm_total: 5,
                method: "plain",
                answer_length: 128,
                output_preview: "Truncated baseline model output preview"
              })
            end
          )
        end)

      assert output =~ "Plan: 5 LLM calls = 2 baseline + 3 frontier bursts"
      assert output =~ "Stage 1/3 baseline reachable archive"
      assert output =~ "LLM 1/5 baseline 1/2 plain started"
      assert output =~ "Why: define cells"
      assert output =~ "input=\"Field prompt"
      assert output =~ "preview=\"Truncated baseline"
    end

    test "verbose progress covers errors, rejections, frontier, trace, and heartbeat summaries" do
      output =
        capture_io(:stderr, fn ->
          Progress.with_heartbeat(
            [verbose: true, heartbeat_ms: 1, preview_chars: 50],
            :test_run,
            fn opts ->
              Progress.event(opts, :mix_frontier_start, %{
                field: "field",
                model: "gpt-5.4-mini",
                reasoning_effort: :low,
                dry_run: false
              })

              Progress.event(opts, :run_plan, %{
                baseline_calls: 1,
                frontier_bursts: 1,
                total_llm_calls: 2,
                concurrency: 1
              })

              Progress.event(opts, :compare_start, %{baseline_methods: 1, branching: 1})

              Progress.event(opts, :baseline_call_start, %{
                index: 1,
                total: 1,
                llm_index: 1,
                llm_total: 2,
                method: "seed_injection",
                input_preview: "baseline input"
              })

              Progress.event(opts, :baseline_call_rejected, %{
                index: 1,
                total: 1,
                llm_index: 1,
                llm_total: 2,
                method: "seed_injection",
                reason: "artifact",
                output_preview: "bad"
              })

              Progress.event(opts, :baseline_call_start, %{
                index: 2,
                total: 2,
                llm_index: 1,
                llm_total: 2,
                method: "paraphrase",
                input_preview: "baseline error"
              })

              Progress.event(opts, :baseline_call_error, %{
                index: 2,
                total: 2,
                llm_index: 1,
                llm_total: 2,
                method: "temperature:0.7",
                reason: "boom"
              })

              Progress.event(opts, :baseline_done, %{accepted: 0})

              Progress.event(opts, :frontier_start, %{branching: 1})
              Progress.event(opts, :branch_start, %{count: 1, concurrency: 1, timeout_ms: 10})

              Progress.event(opts, :burst_call_start, %{
                index: 1,
                total: 1,
                llm_index: 2,
                llm_total: 2,
                model: "gpt-5.4-mini",
                temperature: 1.1,
                input_preview: "burst input"
              })

              Progress.event(opts, :burst_call_error, %{
                index: 1,
                total: 1,
                llm_index: 2,
                llm_total: 2,
                reason: "timeout"
              })

              Progress.event(opts, :burst_call_start, %{
                index: 2,
                total: 2,
                llm_index: 2,
                llm_total: 2,
                model: "gpt-5.4-mini",
                temperature: 1.2,
                input_preview: "burst done"
              })

              Progress.event(opts, :burst_call_done, %{
                index: 2,
                total: 2,
                llm_index: 2,
                llm_total: 2,
                status: :accepted,
                seed_coverage: 0.8,
                answer_length: 12,
                output_preview: "burst output"
              })

              Progress.event(opts, :branch_done, %{count: 1, accepted: 0, rejected: 0, errors: 1})
              Progress.event(opts, :frontier_done, %{total: 1, accepted: 0, rejected: 1})

              Progress.event(opts, :frontier_report_done, %{
                accepted: 0,
                rejected: 1,
                novel_frontier_cell_count: 0,
                archive_coverage: 0.0,
                seed_coverage: 0.0
              })

              Progress.event(opts, :trace_written, %{path: "tmp/x.json"})
              Progress.event(opts, :mix_frontier_done)
              Progress.event(opts, :unknown_event, %{a: 1})
              Process.sleep(20)
            end
          )
        end)

      assert output =~ "Starting frontier run"
      assert output =~ "external seed-injection baseline"
      assert output =~ "Preparing comparison"
      assert output =~ "paraphrase"
      assert output =~ "temperature:0.7 failed"
      assert output =~ "Baseline archive complete"
      assert output =~ "rejected from reachable archive"
      assert output =~ "Stage 2/3 frontier exploration"
      assert output =~ "failed"
      assert output =~ "accepted"
      assert output =~ "Trace written"
      assert output =~ "unknown_event"
      assert output =~ "Still running"
    end

    test "serializes a frontier report into traceable evidence" do
      field = AntiAgents.field("trace field")

      burst = %BurstResult{
        field: field,
        seed: "nonce",
        random_string: "abcdef123456",
        mapping_trace: %{"decisions" => [%{"axis" => "ontology", "chunk" => 0}]},
        mapping_verification: %{valid?: true, coverage: 0.5},
        answer: "A traceable answer.",
        raw_output: "raw",
        status: :accepted,
        descriptor: %{cell: %{length: :short}},
        coherence: 0.8,
        seed_coverage: 0.5,
        score: %{overall: 0.7}
      }

      report = %FrontierReport{
        field: field,
        exemplars: [burst],
        reachable_archive: [burst],
        frontier_cell_count: 1,
        reachable_cell_count: 1,
        novel_frontier_cell_count: 1,
        coverage_delta: 0.5,
        mapping_traces: [burst.mapping_trace],
        metrics: %{distinct: 1, coherence: 0.8, seed_coverage: 0.5, archive_coverage: 1.0}
      }

      trace = AntiAgents.Trace.report(report, model: "gpt-5.4-mini", reasoning_effort: :low)

      assert trace["synthesis"]["essential_aspect"] =~ "entropy-first"
      assert trace["run"]["model"] == "gpt-5.4-mini"
      assert trace["evidence"]["meaningful_signal"] == true
      assert trace["evidence"]["reachable_baseline_count"] == 1
      assert trace["evidence"]["novel_frontier_cell_count"] == 1
      assert trace["evidence"]["coverage_delta"] == 0.5
      assert length(trace["reachable_archive"]) == 1
      assert hd(trace["exemplars"])["random_string"] == "abcdef123456"
      assert hd(trace["exemplars"])["mapping_verification"]["valid?"] == true
      refute Map.has_key?(hd(trace["exemplars"]), "raw_output")
    end
  end

  def valid_burst_json(random_string, answer, opts \\ []) do
    random_string
    |> valid_burst_map(answer, opts)
    |> Jason.encode!()
  end

  def valid_burst_map(random_string, answer, opts \\ []) do
    axes = Keyword.get(opts, :axes, ["ontology", "metaphor", "closure"])
    chunks = Keyword.get(opts, :chunks, Enum.to_list(0..(length(axes) - 1)))
    chunk_size = Keyword.get(opts, :chunk_size, 4)

    decisions =
      axes
      |> Enum.zip(chunks)
      |> Enum.map(fn {axis, chunk} ->
        chunk_text = chunk_text(random_string, chunk, chunk_size)
        hash = Scoring.local_hash(axis, chunk_text, chunk)

        %{
          "axis" => axis,
          "chunk" => chunk,
          "hash" => hash,
          "choice" => rem(hash, 7),
          "value" => "#{axis}:#{chunk_text}"
        }
      end)

    %{
      "random_string" => random_string,
      "mapping" => %{"decisions" => decisions},
      "answer" => answer
    }
  end

  defp chunk_text(random_string, chunk, chunk_size) do
    random_string
    |> String.slice(chunk * chunk_size, chunk_size)
    |> to_string()
  end

  defp collect_client_calls(count), do: collect_client_calls(count, [])

  defp collect_client_calls(0, acc), do: Enum.reverse(acc)

  defp collect_client_calls(count, acc) do
    receive do
      {:client_call, prompt, opts} ->
        collect_client_calls(count - 1, [{prompt, opts} | acc])
    after
      500 ->
        flunk("expected #{count} more client calls")
    end
  end

  defp collect_slow_client_calls(count), do: collect_slow_client_calls(count, [])

  defp collect_slow_client_calls(0, acc), do: Enum.reverse(acc)

  defp collect_slow_client_calls(count, acc) do
    receive do
      {:slow_client_call, prompt, at} ->
        collect_slow_client_calls(count - 1, [{prompt, at} | acc])
    after
      1_000 ->
        flunk("expected #{count} more slow client calls")
    end
  end
end
