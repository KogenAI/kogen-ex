defmodule Kogen.Harness.DeveloperState do
  @moduledoc false

  @enforce_keys [
    :items,
    :authority,
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
          authority: String.t(),
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
