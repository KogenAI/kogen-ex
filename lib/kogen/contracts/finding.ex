defmodule Kogen.Contracts.Finding do
  @moduledoc "A source finding shared by check feedback and quality reports."

  @enforce_keys [:tool, :rule, :severity, :message]
  defstruct @enforce_keys ++ [:path, :line, :col, :symbol]

  @type t :: %__MODULE__{
          tool: String.t(),
          rule: String.t(),
          severity: :error | :warning | :note,
          message: String.t(),
          path: Path.t() | nil,
          line: pos_integer() | nil,
          col: pos_integer() | nil,
          symbol: String.t() | nil
        }
end
