defmodule Kogen.Harness.Developer do
  @moduledoc false

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Developer.Budget
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
      items: initial_items(intent_text, plan, resume, opts.repairs_left),
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
        developer_turn(opts, prompt, state, remaining_ms, system_note)
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

  defp handle_response(opts, prompt, state, %ModelResponse{tool_calls: []}),
    do: done_claim(opts, prompt, state)

  defp handle_response(opts, prompt, state, %ModelResponse{tool_calls: calls}) do
    with {:ok, next} <- run_tool_calls(opts, state, calls),
         {:ok, next, _restored?} <- restore_protected(opts, next) do
      developer_loop(opts, prompt, next)
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
        with :ok <- Recording.append(opts, :gate, :develop, state.turns, gate) do
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

  defp run_tool_calls(opts, state, calls) do
    Enum.reduce_while(calls, {:ok, state}, fn %ToolCall{} = call, {:ok, current} ->
      case run_tool_call(opts, current, call) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_tool_call(opts, state, call) do
    with :ok <- Recording.append(opts, :tool_call, :develop, state.turns, call) do
      result = Tools.run(opts, call, Codec.tool_names(:developer, opts.builder_tools))
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

  defp initial_items(intent_text, plan, nil, repairs_left) do
    [Codec.user_item(initial_user_text(intent_text, plan, repairs_left))]
  end

  defp initial_items(
         intent_text,
         plan,
         %{fresh: true, previous_items: [], failure_text: failure_text},
         repairs_left
       )
       when is_binary(failure_text) do
    user_text =
      initial_user_text(intent_text, plan, repairs_left) <>
        "\n\nEscalation summary:\n" <> failure_text

    [Codec.user_item(user_text)]
  end

  defp initial_items(
         _intent_text,
         _plan,
         %{previous_items: items, failure_text: failure_text},
         _repairs_left
       )
       when is_list(items) and is_binary(failure_text) do
    items ++
      [
        Codec.user_item(
          "Kogen's controller reported this failure. Continue the same session and fix it:\n\n" <>
            failure_text
        )
      ]
  end

  defp initial_items(intent_text, plan, _invalid_resume, repairs_left) do
    [Codec.user_item(initial_user_text(intent_text, plan, repairs_left))]
  end

  defp initial_user_text(intent_text, plan, repairs_left) do
    plan_content = plan_content(plan)

    String.trim("""
    Approved Intent:
    #{intent_text}

    #{plan_content}

    The controller supplied a remaining repair budget of #{repairs_left} pass(es). The Build Cycle owns that budget.
    Begin work in the supplied worktree.
    """)
  end

  defp plan_content(%Plan{builder_addendum: addendum}) when is_binary(addendum), do: addendum
  defp plan_content(%Plan{text: text}), do: "Implementation plan advice:\n" <> text
  defp plan_content(_plan), do: "Implementation plan advice:\nNo technical plan was supplied."

  defp developer_prompt(%Opts{builder_tools: :full}), do: {:ok, @developer_prompt}

  defp developer_prompt(%Opts{builder_tools: :shell}) do
    {:ok,
     @developer_prompt <>
       "\n\nShell-only recipe: acceptance tests and the Intent files are read-only, including " <>
       "when using shell commands or formatters. Inspect with `sed -n`, `grep -n`, or `grep -R`; do not " <>
       "assume `rg` or a shell `apply_patch` command is installed. Make focused edits with " <>
       "`python3 - <<'PY'`. Run Elixir commands through `mise exec -- ...` so the pinned Elixir and " <>
       "Erlang versions are used; a direct Elixir wrapper can fail to find `erl`. Combine related reads " <>
       "and keep command output focused. All file changes must stay inside the worktree."}
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
