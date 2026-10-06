defmodule Kogen.Contracts.Receipt do
  @moduledoc "Evidence that a named check passed for a candidate tree."

  @enforce_keys [:tree, :check, :exit_status, :log_sha256, :at]
  defstruct @enforce_keys ++ [analysis: :complete, duration_ms: nil]

  @type t :: %__MODULE__{
          duration_ms: non_neg_integer() | nil,
          tree: String.t(),
          check: String.t(),
          exit_status: integer(),
          analysis: :complete | :incomplete,
          log_sha256: String.t(),
          at: DateTime.t()
        }
end
