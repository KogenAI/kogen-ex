defmodule Kogen.Contracts.ExchangeRequest do
  @moduledoc false

  @enforce_keys [
    :stage,
    :turn,
    :model,
    :effort,
    :instructions,
    :items,
    :tool_names,
    :remaining_ms
  ]
  defstruct @enforce_keys ++ [measurements: %{}]

  @type tool_name :: :read | :search | :edit | :write | :shell | :tool_output | :finish

  @type t :: %__MODULE__{
          stage: atom(),
          turn: non_neg_integer(),
          model: String.t(),
          effort: String.t(),
          instructions: String.t(),
          measurements: map(),
          items: [map()],
          tool_names: [tool_name()],
          remaining_ms: non_neg_integer() | :infinity
        }
end
