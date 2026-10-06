defmodule Kogen.Contracts.Finding do
  @moduledoc "Complete diagnostic records with location-independent, tool-scoped identities."

  @enforce_keys [:tool, :rule, :severity, :message]
  defstruct @enforce_keys ++ [:id, :path, :line, :col, :symbol, :explanation, :hint]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          tool: String.t(),
          rule: String.t() | nil,
          severity: :error | :warning | :note,
          message: String.t(),
          path: Path.t() | nil,
          line: pos_integer() | nil,
          col: pos_integer() | nil,
          symbol: String.t() | nil,
          explanation: String.t() | nil,
          hint: String.t() | nil
        }

  @spec record(map()) :: t()
  def record(%__MODULE__{} = finding), do: finding |> Map.from_struct() |> record()

  def record(finding) do
    finding
    |> Map.put_new(:explanation, nil)
    |> Map.put(:hint, Map.get(finding, :hint) || hint(finding.message <> "\n" <> (Map.get(finding, :explanation) || "")))
    |> Map.put(:id, identity(finding))
    |> then(&struct!(__MODULE__, &1))
  end

  defp identity(finding) do
    identity =
      if finding.tool == "exunit" and is_binary(Map.get(finding, :symbol)),
        do: {finding.tool, Map.get(finding, :path), finding.symbol},
        else:
          {finding.tool, finding.rule, Map.get(finding, :path), Map.get(finding, :symbol),
           normalize(finding.message)}

    identity
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp hint(message) do
    case Regex.run(~r/(?:hint|suggestion):\s*(.+)/is, message, capture: :all_but_first) do
      [hint] -> String.trim(hint)
      _other -> nil
    end
  end
end
