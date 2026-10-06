defmodule Kogen.Checks.LedgerRow do
  @moduledoc "One acceptance test result written by the controller formatter."

  @enforce_keys [:tag, :test, :status]
  defstruct [:tag, :test, :status]

  @type status :: :passed | :failed | :skipped | :excluded | :invalid
  @type t :: %__MODULE__{tag: String.t(), test: String.t(), status: status()}
end
