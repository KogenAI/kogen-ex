defmodule Kogen.Conversation.Budget do
  @moduledoc false

  @spec note(map(), pos_integer()) :: {map(), String.t() | nil}
  def note(%{budget_note_sent?: false} = state, max_turns) do
    if state.turns >= div(max_turns * 4 + 4, 5) do
      remaining_turns = max_turns - state.turns

      note =
        "System note: #{remaining_turns} turns remain. Run the targeted tests now and finish the smallest complete change."

      {%{state | budget_note_sent?: true}, note}
    else
      {state, nil}
    end
  end

  def note(%{} = state, _max_turns), do: {state, nil}
end
