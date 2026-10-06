defmodule Kogen.Contracts.CheckOutput do
  @moduledoc "The command output and workspace needed to analyze check feedback."

  @enforce_keys [:name, :argv, :exit_status, :timed_out, :output, :log_path, :workdir]
  defstruct @enforce_keys ++ [duration_ms: 0]

  @type t :: %__MODULE__{
          duration_ms: non_neg_integer(),
          name: String.t(),
          argv: [String.t()],
          exit_status: integer() | nil,
          timed_out: boolean(),
          output: String.t(),
          log_path: Path.t() | nil,
          workdir: Path.t()
        }
end
