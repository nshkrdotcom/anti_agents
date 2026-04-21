defmodule AntiAgentsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AntiAgents.{BurstResult, Field, FrontierReport}
  alias AntiAgents.{Bursts, Progress, Scoring}

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
       """
       <random_string>seed-value</random_string>
       <mapping>{"decisions":[{"axis":"ontology","chunk":0,"value":"x"},{"axis":"metaphor","chunk":2,"value":"y"},{"axis":"closure","chunk":3,"value":"z"}]}</mapping>
       <answer>A coherent and novel reply with multiple local decisions.</answer>
       """}
    end
  end

  defmodule PrefixRejectClient do
    def complete(_prompt, _opts) do
      {:ok,
       """
       <random_string>seed-value</random_string>
       <mapping>{"decisions":[{"axis":"ontology","chunk":0,"value":"x"},{"axis":"syntax","chunk":0,"value":"y"}]}</mapping>
       <answer>Looks okay.</answer>
       """}
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
       Jason.encode!(%{
         "random_string" => "artifact-seed",
         "mapping" => %{
           "decisions" => [
             %{"axis" => "ontology", "chunk" => 0, "value" => "x"},
             %{"axis" => "metaphor", "chunk" => 1, "value" => "y"},
             %{"axis" => "closure", "chunk" => 2, "value" => "z"}
           ]
         },
         "answer" => nested_answer
       })}
    end
  end

  defmodule PromptEchoClient do
    def complete(_prompt, _opts) do
      {:ok,
       Jason.encode!(%{
         "random_string" => "echo-seed",
         "mapping" => %{
           "decisions" => [
             %{"axis" => "ontology", "chunk" => 0, "value" => "x"},
             %{"axis" => "metaphor", "chunk" => 1, "value" => "y"},
             %{"axis" => "closure", "chunk" => 2, "value" => "z"}
           ]
         },
         "answer" => "Coordinate nonce: echo-seed Field prompt: leaked prompt text"
       })}
    end
  end

  defmodule ContractClient do
    def complete(prompt, opts) do
      send(opts[:test_pid], {:client_call, prompt, opts})

      if String.contains?(prompt, "Produce exactly one exploration") do
        {:ok,
         Jason.encode!(%{
           "random_string" => "contract-seed",
           "mapping" => %{
             "decisions" => [
               %{"axis" => "ontology", "chunk" => 0, "value" => "x"},
               %{"axis" => "metaphor", "chunk" => 1, "value" => "y"},
               %{"axis" => "closure", "chunk" => 2, "value" => "z"}
             ]
           },
           "answer" => "Frontier answer text."
         })}
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
         Jason.encode!(%{
           "random_string" => "slow-seed",
           "mapping" => %{
             "decisions" => [
               %{"axis" => "ontology", "chunk" => 0, "value" => "x"},
               %{"axis" => "metaphor", "chunk" => 1, "value" => "y"}
             ]
           },
           "answer" => "Frontier answer text."
         })}
      else
        Process.sleep(120)
        {:ok, "Slow baseline answer."}
      end
    end
  end

  defmodule FrontierClient do
    def complete(prompt, _opts) do
      if String.contains?(prompt, "<random_string>") do
        {:ok,
         """
         <random_string>seed-value</random_string>
         <mapping>{"decisions":[{"axis":"ontology","chunk":0,"value":"x"},{"axis":"metaphor","chunk":2,"value":"y"}]}</mapping>
         <answer>Novel frontier output with different framing and metaphor.</answer>
         """}
      else
        {:ok, "baseline response"}
      end
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
      assert burst.random_string == "seed-value"
      assert burst.mapping_trace["decisions"] |> length() == 3
      assert burst.answer == "A coherent and novel reply with multiple local decisions."
      assert burst.seed_coverage > 0.0
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

    test "synthesizes a mapping when the backend returns a plain answer" do
      field = AntiAgents.field("fallback", axes: [:ontology, :metaphor, :syntax])

      burst =
        Bursts.burst(field,
          client: PlainClient,
          client_opts: [],
          seed: "plain-seed",
          coordinate: [length: 12, chunk: 4]
        )

      assert burst.status == :accepted
      assert burst.answer == "A plain answer without structure."
      assert burst.rejection_reason =~ "unstructured"
      assert length(burst.mapping_trace["decisions"]) == length(field.axes)
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
      assert is_float(report.delta_frontier)
      assert is_list(report.exemplars)
      assert is_list(report.reachable_archive)
      assert is_list(report.mapping_traces)
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
      assert is_number(compare.delta_frontier)
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
        assert String.contains?(prompt, "Return only the answer text")
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
      <mapping>{"decisions":[{"axis":"ontology","chunk":1},{"axis":"syntax","chunk":2}]}</mapping>
      <answer>One two three four five six seven eight.</answer>
      """

      assert {:ok, parsed} = Scoring.parse_burst_output(output)
      assert parsed.random_string == "abc"
      assert parsed.mapping["decisions"] |> length() == 2

      coverage = Scoring.seed_coverage(parsed.mapping, 2)
      assert coverage >= 0.5
    end

    test "caps seed coverage at one when mappings over-report chunks" do
      mapping = %{
        "decisions" =>
          Enum.map(0..5, fn chunk -> %{"axis" => "axis", "chunk" => chunk, "value" => "x"} end)
      }

      assert Scoring.seed_coverage(mapping, 3) == 1.0
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
      assert opts[:model] == "gpt-5.4-mini"
      assert opts[:reasoning_effort] == :low
      assert opts[:heat][:answer] == 1.18
      assert opts[:baseline] == [:plain, :paraphrase, {:temperature, [0.8, 1.0]}]
      assert opts[:field][:toward] == ["machine pastoral"]
      assert opts[:field][:away_from] == ["standard sci-fi"]
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

    test "serializes a frontier report into traceable evidence" do
      field = AntiAgents.field("trace field")

      burst = %BurstResult{
        field: field,
        seed: "nonce",
        random_string: "abcdef123456",
        mapping_trace: %{"decisions" => [%{"axis" => "ontology", "chunk" => 0}]},
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
        delta_frontier: 1.0,
        mapping_traces: [burst.mapping_trace],
        metrics: %{distinct: 1, coherence: 0.8, seed_coverage: 0.5, archive_coverage: 1.0}
      }

      trace = AntiAgents.Trace.report(report, model: "gpt-5.4-mini", reasoning_effort: :low)

      assert trace["synthesis"]["essential_aspect"] =~ "entropy-first"
      assert trace["run"]["model"] == "gpt-5.4-mini"
      assert trace["evidence"]["meaningful_signal"] == true
      assert trace["evidence"]["reachable_baseline_count"] == 1
      assert length(trace["reachable_archive"]) == 1
      assert hd(trace["exemplars"])["random_string"] == "abcdef123456"
      refute Map.has_key?(hd(trace["exemplars"]), "raw_output")
    end
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
