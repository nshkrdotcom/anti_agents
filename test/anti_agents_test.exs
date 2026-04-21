defmodule AntiAgentsTest do
  use ExUnit.Case, async: true

  alias AntiAgents.{BurstResult, Field, FrontierReport}
  alias AntiAgents.{Bursts, Scoring}

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

      burst =
        Bursts.burst(field,
          client: BurstClient,
          client_opts: [],
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
                 "--baseline",
                 "plain,paraphrase,temp:0.8|1.0",
                 "--toward",
                 "machine pastoral",
                 "--away-from",
                 "standard sci-fi"
               ])

      assert prompt == "memory field"
      assert opts[:dry_run] == true
      assert opts[:branching] == 12
      assert opts[:model] == "gpt-5.4-mini"
      assert opts[:reasoning_effort] == :low
      assert opts[:heat][:answer] == 1.18
      assert opts[:baseline] == [:plain, :paraphrase, {:temperature, [0.8, 1.0]}]
      assert opts[:field][:toward] == ["machine pastoral"]
      assert opts[:field][:away_from] == ["standard sci-fi"]
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
        delta_frontier: 1.0,
        mapping_traces: [burst.mapping_trace],
        metrics: %{distinct: 1, coherence: 0.8, seed_coverage: 0.5, archive_coverage: 1.0}
      }

      trace = AntiAgents.Trace.report(report, model: "gpt-5.4-mini", reasoning_effort: :low)

      assert trace["synthesis"]["essential_aspect"] =~ "entropy-first"
      assert trace["run"]["model"] == "gpt-5.4-mini"
      assert trace["evidence"]["meaningful_signal"] == true
      assert hd(trace["exemplars"])["random_string"] == "abcdef123456"
      refute Map.has_key?(hd(trace["exemplars"]), "raw_output")
    end
  end
end
