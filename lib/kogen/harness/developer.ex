defmodule Kogen.Harness.DeveloperState do
  @moduledoc false

  @enforce_keys [
    :items,
    :usage,
    :turns,
    :empty_refusals,
    :started_at,
    :deadline,
    :transcript_path
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          items: [map()],
          usage: Kogen.Harness.Usage.t(),
          turns: non_neg_integer(),
          empty_refusals: non_neg_integer(),
          started_at: integer(),
          deadline: integer(),
          transcript_path: Path.t()
        }
end

defmodule Kogen.Harness.Developer do
  @moduledoc false

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness.Codec
  alias Kogen.Harness.DeveloperState
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request, as: ExchangeRequest
  alias Kogen.Harness.Gate
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Plan
  alias Kogen.Harness.Recording
  alias Kogen.Harness.Result
  alias Kogen.Harness.Tools
  alias Kogen.Harness.Usage
  alias Kogen.Tooling.Error
  alias Kogen.Tooling.ToolResult

  @empty_done_message "Kogen found no changed files. Make the requested change before claiming done."
  @developer_prompt_source Path.expand("../../../priv/prompts/developer.md", __DIR__)
  @external_resource @developer_prompt_source
  @developer_prompt File.read!(@developer_prompt_source)

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
      started_at: started_at,
      deadline: started_at + opts.limits.wall_ms,
      transcript_path: transcript_path
    }

    developer_loop(opts, prompt, state)
  end

  defp developer_loop(opts, prompt, %DeveloperState{} = state) do
    remaining_ms = max(state.deadline - System.monotonic_time(:millisecond), 0)

    cond do
      state.turns >= opts.limits.max_turns -> {:ok, result(:gave_up, nil, state)}
      remaining_ms == 0 -> {:ok, result(:gave_up, nil, state)}
      true -> developer_turn(opts, prompt, state, remaining_ms)
    end
  end

  defp developer_turn(opts, prompt, state, remaining_ms) do
    {model, effort} = opts.models.builder
    turn = state.turns + 1

    exchange_request = %ExchangeRequest{
      stage: :develop,
      turn: turn,
      model: model,
      effort: effort,
      instructions: prompt,
      items: state.items,
      tool_names: Codec.tool_names(:developer, opts.builder_tools),
      remaining_ms: remaining_ms
    }

    case Exchange.respond(opts, exchange_request) do
      {:ok, %ModelResponse{} = response} ->
        state = accept_response(state, response)

        if deadline_passed?(state),
          do: {:ok, result(:gave_up, nil, state)},
          else: handle_response(opts, prompt, state, response)

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
    with {:ok, next} <- run_tool_calls(opts, state, calls) do
      developer_loop(opts, prompt, next)
    end
  end

  defp done_claim(opts, prompt, state) do
    with {:ok, changed?} <- changed_files?(opts) do
      if changed? or state.empty_refusals > 0 do
        run_gate(opts, state)
      else
        refuse_empty_done(opts, prompt, state)
      end
    end
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
    case Gate.run(opts, state.deadline) do
      {:ok, gate} ->
        with :ok <- Recording.append(opts, :gate, :develop, state.turns, gate) do
          outcome =
            case gate.status do
              :pass -> :done
              :fail -> :gate_red
              :environment -> :gate_environment
            end

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
    plan_text = if match?(%Plan{}, plan), do: plan.text, else: "No technical plan was supplied."

    String.trim("""
    Approved Intent:
    #{intent_text}

    Implementation plan advice:
    #{plan_text}

    The controller supplied a remaining repair budget of #{repairs_left} pass(es). The Build Cycle owns that budget.
    Begin work in the supplied worktree.
    """)
  end

  defp developer_prompt(%Opts{builder_tools: :full}), do: {:ok, @developer_prompt}

  defp developer_prompt(%Opts{builder_tools: :shell}) do
    {:ok,
     @developer_prompt <>
       "\n\nShell-only recipe: inspect efficiently with `sed -n` and `rg -n`; edit with a " <>
       "short `apply_patch <<'PATCH' ... PATCH` heredoc when available, or a focused " <>
       "`python3 - <<'PY'` edit. Combine related reads and keep command output focused. " <>
       "All file changes must stay inside the worktree."}
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
