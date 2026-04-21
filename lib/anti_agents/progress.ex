defmodule AntiAgents.Progress do
  @moduledoc false

  @default_preview_chars 180

  def enabled?(opts) do
    Keyword.get(opts, :verbose, false) or Keyword.has_key?(opts, :progress_callback)
  end

  def preview(value, limit \\ @default_preview_chars)

  def preview(nil, _limit), do: ""

  def preview(value, limit) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(limit)
  end

  def preview(value, limit), do: value |> inspect() |> preview(limit)

  def event(opts, event, metadata \\ %{}) do
    metadata = metadata_map(metadata)

    opts
    |> Keyword.get(:progress_callback)
    |> call_callback(event, metadata)

    snapshot = update_state(opts, event, metadata)

    if Keyword.get(opts, :verbose, false) do
      IO.puts(:stderr, format(event, metadata, snapshot, opts))
    end

    :ok
  end

  def with_heartbeat(opts, label, fun) when is_function(fun, 0) or is_function(fun, 1) do
    if enabled?(opts) do
      interval = Keyword.get(opts, :heartbeat_ms, 5_000)
      started_at = System.monotonic_time(:millisecond)
      {:ok, state} = Agent.start_link(fn -> initial_state(label, started_at) end)
      opts = Keyword.put(opts, :progress_state, state)
      pid = spawn_link(fn -> heartbeat_loop(opts, label, interval, started_at, 1) end)

      try do
        call_fun(fun, opts)
      after
        send(pid, :stop)
        Process.unlink(pid)
        Agent.stop(state)
      end
    else
      call_fun(fun, opts)
    end
  end

  defp call_fun(fun, _opts) when is_function(fun, 0), do: fun.()
  defp call_fun(fun, opts) when is_function(fun, 1), do: fun.(opts)

  defp heartbeat_loop(opts, label, interval, started_at, tick) do
    receive do
      :stop ->
        :ok
    after
      max(10, interval) ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        event(opts, :heartbeat, %{label: label, elapsed_ms: elapsed_ms, tick: tick})
        heartbeat_loop(opts, label, interval, started_at, tick + 1)
    end
  end

  defp initial_state(label, started_at) do
    %{
      label: label,
      started_at: started_at,
      stage: :starting,
      stage_detail: "starting",
      llm_done: 0,
      llm_total: nil,
      baseline_done: 0,
      baseline_total: nil,
      burst_done: 0,
      burst_total: nil,
      inflight: %{},
      last_duration_ms: nil,
      last_event: nil
    }
  end

  defp update_state(opts, event, metadata) do
    case Keyword.get(opts, :progress_state) do
      nil ->
        nil

      state ->
        Agent.get_and_update(state, fn snapshot ->
          updated = reduce_state(snapshot, event, metadata, opts)
          {updated, updated}
        end)
    end
  rescue
    _error -> nil
  end

  defp reduce_state(state, event, metadata, opts) do
    state
    |> apply_event(event, metadata, opts)
    |> Map.put(:last_event, event)
  end

  defp apply_event(state, :benchmark_plan, metadata, _opts) do
    %{
      state
      | stage: :benchmark,
        stage_detail: "benchmark planned",
        llm_done: 0,
        llm_total: metadata[:planned_llm_calls],
        baseline_done: 0,
        baseline_total: nil,
        burst_done: 0,
        burst_total: nil,
        inflight: %{}
    }
  end

  defp apply_event(state, :benchmark_run_start, metadata, _opts) do
    %{
      state
      | stage: :benchmark,
        stage_detail:
          "benchmark run #{metadata[:run_index]}/#{metadata[:run_total]} field #{metadata[:field_index]}/#{metadata[:field_total]} #{metadata[:field_id]}",
        llm_done: metadata[:llm_done] || state.llm_done,
        llm_total: metadata[:llm_total] || state.llm_total,
        baseline_done: 0,
        baseline_total: nil,
        burst_done: 0,
        burst_total: nil,
        inflight: %{}
    }
  end

  defp apply_event(state, :benchmark_run_done, metadata, _opts) do
    %{
      state
      | stage: :benchmark,
        stage_detail: "benchmark run #{metadata[:run_index]}/#{metadata[:run_total]} complete",
        llm_done: metadata[:llm_done] || state.llm_done,
        llm_total: metadata[:llm_total] || state.llm_total,
        inflight: %{}
    }
  end

  defp apply_event(state, :run_plan, metadata, opts) do
    matched_baseline_calls = metadata[:matched_baseline_calls] || 0
    benchmark_total = Keyword.get(opts, :benchmark_llm_total)
    benchmark_offset = Keyword.get(opts, :benchmark_llm_offset)
    llm_total = benchmark_total || metadata[:total_llm_calls]
    llm_done = if benchmark_total, do: benchmark_offset || state.llm_done, else: state.llm_done

    %{
      state
      | stage: :planned,
        stage_detail: benchmark_stage_detail(opts, "plan announced"),
        llm_done: llm_done,
        llm_total: llm_total,
        baseline_done: 0,
        baseline_total: (metadata[:baseline_calls] || 0) + matched_baseline_calls,
        burst_done: 0,
        burst_total: metadata[:frontier_bursts]
    }
  end

  defp apply_event(state, :baseline_start, metadata, _opts) do
    total =
      case {metadata[:methods], state.baseline_total} do
        {methods, existing} when is_integer(methods) and is_integer(existing) ->
          max(methods, existing)

        {methods, _existing} when is_integer(methods) ->
          methods

        {_methods, existing} ->
          existing
      end

    %{
      state
      | stage: :baseline,
        stage_detail: "building reachable archive",
        baseline_total: total
    }
  end

  defp apply_event(state, :frontier_start, metadata, _opts) do
    %{
      state
      | stage: :frontier,
        stage_detail: "running SSoT frontier bursts",
        burst_total: metadata[:branching] || state.burst_total
    }
  end

  defp apply_event(state, :baseline_call_start, metadata, opts),
    do:
      put_inflight(
        state,
        {:baseline, metadata[:index]},
        inflight_label("baseline #{metadata[:index]}/#{metadata[:total]}", metadata, opts)
      )

  defp apply_event(state, :burst_call_start, metadata, opts),
    do:
      put_inflight(
        state,
        {:burst, metadata[:index]},
        inflight_label("burst #{metadata[:index]}/#{metadata[:total]}", metadata, opts)
      )

  defp apply_event(state, :baseline_call_done, metadata, _opts) do
    state
    |> finish_inflight({:baseline, metadata[:index]})
    |> Map.update!(:baseline_done, &(&1 + 1))
    |> Map.update!(:llm_done, &(&1 + 1))
  end

  defp apply_event(state, :baseline_call_error, metadata, _opts) do
    state
    |> finish_inflight({:baseline, metadata[:index]})
    |> Map.update!(:baseline_done, &(&1 + 1))
    |> Map.update!(:llm_done, &(&1 + 1))
  end

  defp apply_event(state, :baseline_call_rejected, metadata, _opts) do
    state
    |> finish_inflight({:baseline, metadata[:index]})
    |> Map.update!(:baseline_done, &(&1 + 1))
    |> Map.update!(:llm_done, &(&1 + 1))
  end

  defp apply_event(state, :burst_call_done, metadata, _opts) do
    state
    |> finish_inflight({:burst, metadata[:index]})
    |> Map.update!(:burst_done, &(&1 + 1))
    |> Map.update!(:llm_done, &(&1 + 1))
  end

  defp apply_event(state, :burst_call_error, metadata, _opts) do
    state
    |> finish_inflight({:burst, metadata[:index]})
    |> Map.update!(:burst_done, &(&1 + 1))
    |> Map.update!(:llm_done, &(&1 + 1))
  end

  defp apply_event(state, :frontier_report_done, _metadata, _opts),
    do: %{state | stage: :reporting, stage_detail: "scoring archive"}

  defp apply_event(state, :trace_written, _metadata, _opts),
    do: %{state | stage: :done, stage_detail: "trace written"}

  defp apply_event(state, :mix_frontier_done, _metadata, _opts),
    do: %{state | stage: :done, stage_detail: "done"}

  defp apply_event(state, _event, _metadata, _opts), do: state

  defp put_inflight(state, key, label) do
    started_at = System.monotonic_time(:millisecond)
    inflight = Map.put(state.inflight, key, %{label: label, started_at: started_at})
    %{state | inflight: inflight, last_duration_ms: nil}
  end

  defp finish_inflight(state, key) do
    {entry, inflight} = Map.pop(state.inflight, key)
    duration = if entry, do: System.monotonic_time(:millisecond) - entry.started_at

    %{state | inflight: inflight, last_duration_ms: duration}
  end

  defp call_callback(nil, _event, _metadata), do: :ok

  defp call_callback(callback, event, metadata) when is_function(callback, 2) do
    callback.(event, metadata)
    :ok
  rescue
    _error -> :ok
  end

  defp call_callback(_callback, _event, _metadata), do: :ok

  defp format(event, metadata, snapshot, opts) do
    now = DateTime.utc_now() |> Calendar.strftime("%H:%M:%S")
    "[anti_agents] #{now} #{message(event, metadata, snapshot, opts)}"
  end

  defp message(:mix_frontier_start, metadata, _snapshot, _opts) do
    "Starting frontier run | field=#{inspect(preview(metadata[:field], 100))} | model=#{metadata[:model]} | reasoning=#{metadata[:reasoning_effort]} | dry_run=#{metadata[:dry_run]}"
  end

  defp message(:benchmark_plan, metadata, _snapshot, _opts) do
    "Benchmark plan: #{metadata[:field_count]} fields × #{metadata[:repetitions]} repetitions = #{metadata[:run_count]} runs, #{metadata[:planned_llm_calls]} planned LLM calls, #{metadata[:calls_per_run]} calls/run."
  end

  defp message(:benchmark_run_start, metadata, _snapshot, _opts) do
    "Benchmark run #{metadata[:run_index]}/#{metadata[:run_total]} | field #{metadata[:field_index]}/#{metadata[:field_total]} #{metadata[:field_id]} | repetition #{metadata[:repetition]}/#{metadata[:repetitions]} | completed_llm=#{metadata[:llm_done]}/#{metadata[:llm_total]} | this_run_calls=#{metadata[:calls_this_run]}"
  end

  defp message(:benchmark_run_done, metadata, _snapshot, _opts) do
    "Benchmark run #{metadata[:run_index]}/#{metadata[:run_total]} done | field=#{metadata[:field_id]} | completed_llm=#{metadata[:llm_done]}/#{metadata[:llm_total]} | accepted=#{metadata[:accepted]} | adjusted_novel_frontier_cells=#{metadata[:adjusted_novel_frontier_cell_count]}"
  end

  defp message(:run_plan, metadata, _snapshot, opts) do
    matched = metadata[:matched_baseline_calls] || 0

    "#{benchmark_context(opts)}Plan: #{metadata[:total_llm_calls]} LLM calls = #{metadata[:baseline_calls]} baseline + #{metadata[:frontier_bursts]} frontier bursts + #{matched} matched-baseline continuation, concurrency=#{metadata[:concurrency]}. Baseline maps what ordinary prompting can reach; frontier keeps SSoT bursts that land outside that map."
  end

  defp message(:compare_start, metadata, _snapshot, _opts) do
    "Preparing comparison | baseline_methods=#{metadata[:baseline_methods]} | frontier_bursts=#{metadata[:branching]}"
  end

  defp message(:baseline_start, metadata, _snapshot, _opts) do
    "Stage 1/3 baseline reachable archive: #{metadata[:methods]} calls. Why: define cells that plain/paraphrase/temperature already reach."
  end

  defp message(:baseline_call_start, metadata, _snapshot, opts) do
    "#{llm_label(metadata, opts)} baseline #{metadata[:index]}/#{metadata[:total]} #{metadata[:method]} started | #{method_reason(metadata[:method])} | input=#{inspect(preview(metadata[:input_preview], preview_limit(opts)))}"
  end

  defp message(:baseline_call_done, metadata, snapshot, opts) do
    "#{llm_label(metadata, opts)} baseline #{metadata[:index]}/#{metadata[:total]} #{metadata[:method]} done in #{duration(snapshot)} | output_chars=#{metadata[:answer_length]} | preview=#{inspect(preview(metadata[:output_preview], preview_limit(opts)))}"
  end

  defp message(:baseline_call_error, metadata, snapshot, opts) do
    "#{llm_label(metadata, opts)} baseline #{metadata[:index]}/#{metadata[:total]} #{metadata[:method]} failed in #{duration(snapshot)} | reason=#{metadata[:reason]}"
  end

  defp message(:baseline_call_rejected, metadata, snapshot, opts) do
    "#{llm_label(metadata, opts)} baseline #{metadata[:index]}/#{metadata[:total]} #{metadata[:method]} rejected from reachable archive in #{duration(snapshot)} | reason=#{metadata[:reason]} | preview=#{inspect(preview(metadata[:output_preview], preview_limit(opts)))}"
  end

  defp message(:baseline_call_retry, metadata, _snapshot, opts) do
    "#{llm_label(metadata, opts)} baseline #{metadata[:index]}/#{metadata[:total]} #{metadata[:method]} retrying #{metadata[:attempt]}/#{metadata[:retry_budget]} after artifact | reason=#{metadata[:reason]} | preview=#{inspect(preview(metadata[:output_preview], preview_limit(opts)))}"
  end

  defp message(:baseline_done, metadata, _snapshot, _opts) do
    "Baseline archive complete | accepted=#{metadata[:accepted]} | retries=#{metadata[:retry_count] || 0} | permanent_losses=#{metadata[:permanent_loss_count] || 0}. Next: run frontier bursts against this reachable map."
  end

  defp message(:frontier_start, metadata, _snapshot, _opts) do
    "Stage 2/3 frontier exploration: #{metadata[:branching]} SSoT bursts. Why: internal random string -> local mapping -> answer, then reject collapse/reachable duplicates."
  end

  defp message(:branch_start, metadata, _snapshot, _opts) do
    "Launching frontier burst batch | bursts=#{metadata[:count]} | concurrency=#{metadata[:concurrency]} | timeout_ms=#{metadata[:timeout_ms]}"
  end

  defp message(:burst_call_start, metadata, _snapshot, opts) do
    "#{llm_label(metadata, opts)} burst #{metadata[:index]}/#{metadata[:total]} started | model=#{metadata[:model]} temp=#{metadata[:temperature]} | asks for random_string + mapping JSON + answer | input=#{inspect(preview(metadata[:input_preview], preview_limit(opts)))}"
  end

  defp message(:burst_call_done, metadata, snapshot, opts) do
    "#{llm_label(metadata, opts)} burst #{metadata[:index]}/#{metadata[:total]} #{metadata[:status]} in #{duration(snapshot)} | seed_coverage=#{metadata[:seed_coverage]} | answer_chars=#{metadata[:answer_length]} | preview=#{inspect(preview(metadata[:output_preview], preview_limit(opts)))}"
  end

  defp message(:burst_call_error, metadata, snapshot, opts) do
    "#{llm_label(metadata, opts)} burst #{metadata[:index]}/#{metadata[:total]} failed in #{duration(snapshot)} | reason=#{metadata[:reason]}"
  end

  defp message(:branch_done, metadata, _snapshot, _opts) do
    "Frontier burst batch complete | total=#{metadata[:count]} | accepted=#{metadata[:accepted]} | rejected=#{metadata[:rejected]} | errors=#{metadata[:errors]}"
  end

  defp message(:frontier_done, metadata, _snapshot, _opts) do
    "Frontier raw archive complete | total=#{metadata[:total]} | accepted=#{metadata[:accepted]} | rejected=#{metadata[:rejected]}. Next: score novelty against baseline."
  end

  defp message(:frontier_report_done, metadata, _snapshot, _opts) do
    "Stage 3/3 report complete | accepted=#{metadata[:accepted]} | rejected=#{metadata[:rejected]} | novel_frontier_cells=#{metadata[:novel_frontier_cell_count]} | archive_coverage=#{metadata[:archive_coverage]} | mean_seed_coverage=#{metadata[:seed_coverage]}"
  end

  defp message(:trace_written, metadata, _snapshot, _opts) do
    "Trace written: #{metadata[:path]}"
  end

  defp message(:mix_frontier_done, _metadata, _snapshot, _opts), do: "Run complete."

  defp message(:heartbeat, metadata, snapshot, _opts) do
    "Still running after #{seconds(metadata[:elapsed_ms])}s | #{progress_summary(snapshot)} | inflight=#{inflight_summary(snapshot)}"
  end

  defp message(event, metadata, _snapshot, _opts) do
    "#{event} #{inspect(metadata)}"
  end

  defp method_reason("plain"), do: "ordinary prompt baseline"
  defp method_reason("paraphrase"), do: "paraphrase baseline"
  defp method_reason("seed_injection"), do: "external seed-injection baseline"
  defp method_reason("temperature:" <> temp), do: "temperature sweep baseline at #{temp}"
  defp method_reason(_method), do: "baseline method"

  defp llm_label(metadata, opts) do
    local = "LLM #{metadata[:llm_index]}/#{metadata[:llm_total]}"

    case Keyword.get(opts, :benchmark_run_index) do
      nil ->
        local

      run_index ->
        global_done = Keyword.get(opts, :benchmark_llm_offset, 0) + metadata[:llm_index]
        global_total = Keyword.get(opts, :benchmark_llm_total, metadata[:llm_total])
        run_total = Keyword.get(opts, :benchmark_run_total)
        field_id = Keyword.get(opts, :benchmark_field_id)

        "benchmark run #{run_index}/#{run_total} field=#{field_id} | LLM #{global_done}/#{global_total} | local #{local}"
    end
  end

  defp inflight_label(local_label, metadata, opts) do
    case Keyword.get(opts, :benchmark_run_index) do
      nil ->
        local_label

      run_index ->
        global_done = Keyword.get(opts, :benchmark_llm_offset, 0) + metadata[:llm_index]
        global_total = Keyword.get(opts, :benchmark_llm_total, metadata[:llm_total])
        run_total = Keyword.get(opts, :benchmark_run_total)
        field_id = Keyword.get(opts, :benchmark_field_id)

        "benchmark run #{run_index}/#{run_total} field=#{field_id} LLM #{global_done}/#{global_total} #{local_label}"
    end
  end

  defp benchmark_context(opts) do
    case Keyword.get(opts, :benchmark_run_index) do
      nil ->
        ""

      run_index ->
        run_total = Keyword.get(opts, :benchmark_run_total)
        field_id = Keyword.get(opts, :benchmark_field_id)
        "benchmark run #{run_index}/#{run_total} field=#{field_id} | "
    end
  end

  defp benchmark_stage_detail(opts, fallback) do
    case Keyword.get(opts, :benchmark_run_index) do
      nil ->
        fallback

      run_index ->
        run_total = Keyword.get(opts, :benchmark_run_total)
        field_index = Keyword.get(opts, :benchmark_field_index)
        field_total = Keyword.get(opts, :benchmark_field_total)
        field_id = Keyword.get(opts, :benchmark_field_id)
        "benchmark run #{run_index}/#{run_total} field #{field_index}/#{field_total} #{field_id}"
    end
  end

  defp duration(%{last_duration_ms: ms}) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)}s"
  defp duration(_snapshot), do: "?"

  defp progress_summary(nil), do: "progress unavailable"

  defp progress_summary(snapshot) do
    llm =
      case snapshot.llm_total do
        total when is_integer(total) -> "LLM #{snapshot.llm_done}/#{total}"
        _ -> "LLM ?"
      end

    baseline =
      if snapshot.baseline_total do
        "baseline #{snapshot.baseline_done}/#{snapshot.baseline_total}"
      else
        "baseline ?"
      end

    bursts =
      if snapshot.burst_total do
        "bursts #{snapshot.burst_done}/#{snapshot.burst_total}"
      else
        "bursts ?"
      end

    "stage=#{snapshot.stage_detail}; #{llm}; #{baseline}; #{bursts}"
  end

  defp inflight_summary(nil), do: "unknown"

  defp inflight_summary(%{inflight: inflight}) when map_size(inflight) == 0, do: "none"

  defp inflight_summary(%{inflight: inflight}) do
    now = System.monotonic_time(:millisecond)

    inflight
    |> Map.values()
    |> Enum.map_join(", ", fn entry -> "#{entry.label} #{seconds(now - entry.started_at)}s" end)
  end

  defp preview_limit(opts), do: Keyword.get(opts, :preview_chars, @default_preview_chars)

  defp seconds(ms) when is_integer(ms), do: Float.round(ms / 1000, 1)
  defp seconds(_ms), do: "?"

  defp metadata_map(metadata) when is_map(metadata), do: metadata
  defp metadata_map(metadata) when is_list(metadata), do: Map.new(metadata)
  defp metadata_map(_metadata), do: %{}

  defp truncate(value, limit) do
    limit = max(20, limit || @default_preview_chars)

    if String.length(value) > limit do
      String.slice(value, 0, limit - 3) <> "..."
    else
      value
    end
  end
end
