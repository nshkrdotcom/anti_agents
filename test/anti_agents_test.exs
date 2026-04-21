defmodule AntiAgentsTest do
  use ExUnit.Case, async: true

  alias AntiAgents.{BurstResult, Field, FrontierReport}
  alias AntiAgents.{Bursts, Scoring}

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
      assert String.contains?(opts[:input], "Seed string: seed-value")

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
  end
end
