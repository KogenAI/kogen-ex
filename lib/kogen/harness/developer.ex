defmodule Kogen.Harness.Developer do
  @moduledoc false

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Contracts.ToolCall
  alias Kogen.Conversation
  alias Kogen.Conversation.Budget
  alias Kogen.Conversation.BuilderPolicy
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Continuation
  alias Kogen.Harness.DeveloperState
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request, as: ExchangeRequest
  alias Kogen.Harness.Gate
  alias Kogen.Harness.Opts
  alias Kogen.Harness.PhaseTiming
  alias Kogen.Harness.Plan
  alias Kogen.Harness.Recording
  alias Kogen.Harness.Result
  alias Kogen.Harness.Tools
  alias Kogen.Harness.Usage
  alias Kogen.Resilience.Policy
  alias Kogen.Resilience.RequestLog
  alias Kogen.Tooling.Error
  alias Kogen.Tooling.ToolResult

  @empty_done_message "Kogen found no changed files. Make the requested change before claiming done."
  @developer_prompt_source Path.expand("../../../priv/prompts/developer.md", __DIR__)
  @external_resource @developer_prompt_source
  @developer_prompt File.read!(@developer_prompt_source)
  @protected_restore_limit 3

  @spec run(Opts.t(), String.t(), Plan.t() | nil, map() | nil) ::
          {:ok, Result.t()} | {:error, term()}
  def run(%Opts{} = opts, intent_text, plan, resume) do
    with :ok <- validate_limits(opts),
         {:ok, transcript_path} <- Recording.path(opts),
         {:ok, prompt} <- developer_prompt(opts) do
      initialize(opts, intent_text, plan, resume, transcript_path, prompt)
    end
  end

  defp initialize(opts, intent_text, plan, resume, transcript_path, prompt) do
    started_at = System.monotonic_time(:millisecond)

    state = %DeveloperState{
      authority: Conversation.authority(intent_text, plan, opts.repairs_left),
      measurements: Conversation.authority_metrics(intent_text, plan),
      items: Conversation.initial_items(intent_text, plan, resume, opts.repairs_left),
      usage: Usage.zero(),
      turns: 0,
      empty_refusals: 0,
      protected_restores: 0,
      budget_note_sent?: false,
      started_at: started_at,
      deadline: started_at + opts.limits.wall_ms,
      transcript_path: transcript_path
    }

    developer_loop(opts, prompt, state)
  end

  defp developer_loop(opts, prompt, %DeveloperState{} = state) do
    remaining_ms = max(state.deadline - System.monotonic_time(:millisecond), 0)

    cond do
      remaining_ms == 0 ->
        {:ok, result(:wall_cap, nil, state)}

      state.turns >= opts.limits.max_turns ->
        {:ok, result(:turn_cap, nil, state)}

      true ->
        {state, system_note} = Budget.note(state, opts.limits.max_turns)

        with {:ok, state} <- Continuation.prepare(opts, state, remaining_ms) do
          developer_turn(
            opts,
            prompt,
            state,
            max(state.deadline - System.monotonic_time(:millisecond), 0),
            system_note
          )
        end
    end
  end

  defp developer_turn(opts, prompt, state, remaining_ms, system_note) do
    {model, effort} = opts.models.builder
    turn = state.turns + 1

    exchange_request = %ExchangeRequest{
      stage: :develop,
      turn: turn,
      model: model,
      effort: effort,
      instructions: Budget.instructions(prompt, system_note),
      measurements: state.measurements,
      items: state.items,
      tool_names: Codec.tool_names(:developer, opts.builder_tools),
      remaining_ms: remaining_ms
    }

    case Exchange.respond(opts, exchange_request) do
      {:ok, %ModelResponse{} = response} ->
        state = accept_response(state, response)

        if deadline_passed?(state),
          do: {:ok, result(:wall_cap, nil, state)},
          else: handle_response(opts, prompt, state, response)

      # The exchange retries timeouts and stalls until the wall budget cannot cover another
      # attempt, so one reaching here means the wall ran out, not that the provider failed.
      {:error, %ProviderError{class: class} = error} ->
        if Policy.budget_bound?(class),
          do: {:ok, result(:wall_cap, nil, state)},
          else: {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp accept_response(state, response) do
    %{
      state
      | turns: state.turns + 1,
        items: state.items ++ response.raw_items,
        usage: Codec.usage(state.usage, response.usage)
    }
  end

  defp handle_response(opts, prompt, state, %ModelResponse{tool_calls: []}) do
    next = %{state | items: state.items ++ [Codec.user_item(BuilderPolicy.progress_note())]}
    developer_loop(opts, prompt, next)
  end

  defp handle_response(opts, prompt, state, %ModelResponse{tool_calls: calls} = response) do
    with {:ok, next} <- run_tool_calls(opts, state, calls, BuilderPolicy.disposition(response)) do
      if BuilderPolicy.disposition(response) == :finish do
        done_claim(opts, prompt, next)
      else
        with {:ok, next, _restored?} <- restore_protected(opts, next) do
          developer_loop(opts, prompt, next)
        end
      end
    end
  end

  defp done_claim(opts, prompt, state) do
    with {:ok, state, restored?} <- restore_protected(opts, state) do
      if restored?,
        do: developer_loop(opts, prompt, state),
        else: finish_done_claim(opts, prompt, state)
    end
  end

  defp finish_done_claim(opts, prompt, state) do
    with {:ok, changed?} <- changed_files?(opts) do
      if changed? or state.empty_refusals > 0 do
        run_gate(opts, state)
      else
        refuse_empty_done(opts, prompt, state)
      end
    end
  end

  defp restore_protected(%Opts{protected_restorer: nil}, state), do: {:ok, state, false}

  defp restore_protected(%Opts{protected_restorer: restorer} = opts, state)
       when is_function(restorer, 0) do
    case restorer.() do
      {:ok, []} ->
        {:ok, state, false}

      {:ok, paths} when is_list(paths) ->
        with :ok <- record_protected_restores(opts, state, paths) do
          restore_count = state.protected_restores + 1

          next = %{
            state
            | protected_restores: restore_count,
              items: state.items ++ Enum.map(paths, &Codec.user_item(protected_note(&1)))
          }

          if state.protected_restores >= @protected_restore_limit do
            error(
              :protected_restore_limit,
              "The builder changed approved protected files more than #{@protected_restore_limit} times."
            )
          else
            {:ok, next, true}
          end
        end

      {:error, reason} ->
        error(
          :protected_restore_failed,
          "Could not restore approved protected files: #{inspect(reason)}"
        )

      other ->
        error(:protected_restore_failed, "Protected-file restorer returned #{inspect(other)}.")
    end
  end

  defp record_protected_restores(opts, state, paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      event = %{
        event: :protected_restored,
        stage: :develop,
        turn: state.turns,
        path: path,
        detail: "Restored approved bytes after a builder edit."
      }

      case record_event(opts, event) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp record_event(%Opts{} = opts, event) do
    with :ok <- Recording.append(opts, event.event, event.stage, event.turn, event) do
      case opts.event_recorder do
        recorder when is_function(recorder, 1) -> recorder.(event)
        nil -> :ok
      end
    end
  end

  defp protected_note(path) do
    "You changed #{path}; acceptance tests and the Intent are read-only and have been restored. Make the implementation satisfy them."
  end

  defp refuse_empty_done(opts, prompt, state) do
    item = Codec.user_item(@empty_done_message)

    with :ok <-
           Recording.append(opts, :empty_done_refused, :develop, state.turns, @empty_done_message) do
      developer_loop(opts, prompt, %{
        state
        | items: state.items ++ [item],
          empty_refusals: state.empty_refusals + 1
      })
    end
  end

  defp run_gate(opts, state) do
    result =
      PhaseTiming.measure(opts, "build", "gate_run", fn -> Gate.run(opts, state.deadline) end)

    case result do
      {:ok, gate} ->
        with :ok <- Recording.append(opts, :gate, :develop, state.turns, gate),
             :ok <-
               RequestLog.append(Path.dirname(state.transcript_path), %{
                 event: :builder_gate,
                 stage: :develop,
                 turn: state.turns,
                 tags: opts.request_tags,
                 gate_status: gate.status,
                 at: System.system_time(:millisecond)
               }) do
          outcome =
            case gate.status do
              :pass -> :done
              :fail -> :gate_red
              :environment -> :gate_environment
            end

          state = Kogen.Harness.MutationAdvice.deliver(opts, gate, state)
          {:ok, result(outcome, gate, state)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp changed_files?(opts) do
    case opts.changed? do
      changed? when is_function(changed?, 0) ->
        changed?.()

      nil ->
        error(
          :change_detector_missing,
          "The controller did not supply a worktree change detector."
        )
    end
  end

  defp run_tool_calls(opts, state, calls, disposition) do
    Enum.reduce_while(calls, {:ok, state}, fn %ToolCall{} = call, {:ok, current} ->
      case run_tool_call(opts, current, call, disposition) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_tool_call(opts, state, call, disposition) do
    with :ok <- Recording.append(opts, :tool_call, :develop, state.turns, call) do
      result =
        case {call.name, disposition} do
          {"finish", :finish} ->
            %ToolResult{output: BuilderPolicy.finish_result(), is_error: false, paths: []}

          {"finish", _other} ->
            %ToolResult{output: BuilderPolicy.invalid_finish_result(), is_error: true, paths: []}

          _other ->
            Tools.run(opts, call, Codec.tool_names(:developer, opts.builder_tools) -- [:finish])
        end

      append_tool_result(opts, state, call, result)
    end
  end

  defp append_tool_result(opts, state, call, %ToolResult{} = result) do
    with :ok <-
           Recording.append(opts, :tool_result, :develop, state.turns, %{
             call: call,
             result: result
           }) do
      {:ok, %{state | items: state.items ++ [Codec.function_output(call.id, result.output)]}}
    end
  end

  defp developer_prompt(%Opts{builder_tools: :full}), do: {:ok, @developer_prompt}

  defp developer_prompt(%Opts{builder_tools: :shell}) do
    {:ok,
     @developer_prompt <>
       "\n\nShell-only recipe: acceptance tests and the Intent files are read-only, including " <>
       "when using shell commands or formatters. Inspect with `sed -n`, `grep -n`, or `grep -R`; do not " <>
       "assume `rg` or a shell `apply_patch` command is installed. Make focused edits with " <>
       "`python3 - <<'PY'`. Run Elixir commands through `mise exec -- ...` so the pinned Elixir and " <>
       "Erlang versions are used; a direct Elixir wrapper can fail to find `erl`. Inspect only what " <>
       "the next decision needs; combine independent related reads and keep output focused. " <>
       "Emit the command once its arguments are ready. Make one coherent patch, inspect its " <>
       "result, then proceed. Command text contains executable work only, never deliberation " <>
       "or progress prose. All file changes must stay inside the worktree."}
  end

  defp validate_limits(opts) do
    cond do
      not is_integer(opts.limits.max_turns) or opts.limits.max_turns < 1 ->
        error(:invalid_turn_limit, "max_turns must be a positive integer.")

      not is_integer(opts.limits.wall_ms) or opts.limits.wall_ms < 1 ->
        error(:invalid_wall_limit, "wall_ms must be a positive integer.")

      not is_integer(opts.repairs_left) or opts.repairs_left < 0 ->
        error(:invalid_repair_count, "repairs_left must be a non-negative integer.")

      true ->
        :ok
    end
  end

  defp deadline_passed?(state), do: System.monotonic_time(:millisecond) >= state.deadline

  defp result(outcome, gate, state) do
    %Result{
      outcome: outcome,
      gate: gate,
      items: state.items,
      turns: state.turns,
      usage: Usage.to_map(state.usage),
      transcript_path: state.transcript_path
    }
  end

  defp error(reason, detail), do: {:error, %Error{reason: reason, detail: detail}}
end
