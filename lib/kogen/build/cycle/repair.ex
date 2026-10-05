defmodule Kogen.Build.Cycle.Repair do
  @moduledoc false

  # Fixed recipes repair a set number of times. A ladder keeps repairing while each red gate
  # has strictly fewer failures than the last one, up to its per-rung cap.

  alias Kogen.Build.Cycle.State
  alias Kogen.Build.Recipe

  @spec cap(Recipe.t(), non_neg_integer()) :: non_neg_integer()
  def cap(recipe, fixed) do
    case Recipe.ladder(recipe) do
      %{repair_cap: cap} -> cap
      nil -> fixed
    end
  end

  @spec decide(State.t(), atom(), map()) ::
          {:repair, State.t(), map()} | {:stop, atom(), atom()}
  def decide(%State{} = state, reason, detail) do
    cond do
      state.repairs_left == 0 ->
        {:stop, :repair_cap, if(reason == :done_gate_red, do: :gate_red, else: :repair_cap)}

      Recipe.ladder(state.recipe) == nil ->
        {:repair, %{state | repairs_left: state.repairs_left - 1}, detail}

      true ->
        progress(state, detail)
    end
  end

  @doc "Repair detail for a red done gate; fixed recipes may earn one progress repair."
  @spec red_gate(State.t(), map()) :: {State.t(), map()}
  def red_gate(%State{} = state, data) do
    {next, progress} =
      if Recipe.ladder(state.recipe),
        do: {state, nil},
        else: update_test_progress(state, data)

    {next,
     %{
       outcome: :gate_red,
       test_progress: progress,
       failure_count: Map.get(data, :failure_count)
     }}
  end

  defp update_test_progress(state, %{failed_test_count: count})
       when is_integer(count) and count >= 0 do
    previous = state.last_failed_test_count

    grant? =
      not state.progress_repair_used? and is_integer(previous) and count < previous

    next = %{
      state
      | last_failed_test_count: count,
        progress_repair_used?: state.progress_repair_used? or grant?,
        repairs_left: state.repairs_left + if(grant?, do: 1, else: 0)
    }

    {next,
     %{
       previous_failed_test_count: previous,
       failed_test_count: count,
       progress_repair_granted: grant?
     }}
  end

  defp update_test_progress(state, _data), do: {%{state | last_failed_test_count: nil}, nil}

  defp progress(state, detail) do
    count = Map.get(detail, :failure_count)
    previous = state.last_failure_count

    if is_integer(count) and is_integer(previous) and count >= previous do
      {:stop, :no_progress, :no_progress}
    else
      next = %{
        state
        | repairs_left: state.repairs_left - 1,
          last_failure_count: if(is_integer(count), do: count, else: previous)
      }

      {:repair, next,
       Map.put(detail, :progress, %{previous_failure_count: previous, failure_count: count})}
    end
  end
end
