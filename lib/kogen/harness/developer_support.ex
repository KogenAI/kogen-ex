defmodule Kogen.Harness.DeveloperState do
  @moduledoc false

  @enforce_keys [
    :items,
    :usage,
    :turns,
    :empty_refusals,
    :protected_restores,
    :started_at,
    :deadline,
    :transcript_path
  ]
  defstruct @enforce_keys ++ [budget_note_sent?: false]

  @type t :: %__MODULE__{
          items: [map()],
          usage: Kogen.Harness.Usage.t(),
          turns: non_neg_integer(),
          empty_refusals: non_neg_integer(),
          protected_restores: non_neg_integer(),
          budget_note_sent?: boolean(),
          started_at: integer(),
          deadline: integer(),
          transcript_path: Path.t()
        }
end

defmodule Kogen.Harness.Developer.Budget do
  @moduledoc false

  alias Kogen.Harness.DeveloperState

  @spec note(DeveloperState.t(), pos_integer()) :: {DeveloperState.t(), String.t() | nil}
  def note(%DeveloperState{budget_note_sent?: false} = state, max_turns) do
    if state.turns >= div(max_turns * 4 + 4, 5) do
      remaining_turns = max_turns - state.turns

      note =
        "System note: #{remaining_turns} turns remain. Run the targeted tests now and finish the smallest complete change."

      {%{state | budget_note_sent?: true}, note}
    else
      {state, nil}
    end
  end

  def note(%DeveloperState{} = state, _max_turns), do: {state, nil}

  @spec instructions(String.t(), String.t() | nil) :: String.t()
  def instructions(prompt, nil), do: prompt
  def instructions(prompt, note), do: prompt <> "\n\n" <> note
end
