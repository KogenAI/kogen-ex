defmodule Kogen.Intent.Parser.Scheduling do
  @moduledoc false

  @spec parse(map()) :: {:ok, [String.t()], integer()} | {:error, String.t()}
  def parse(attrs) do
    value = Map.get(attrs, "priority", "0")
    parsed = if is_binary(value), do: Integer.parse(value), else: :error

    case parsed do
      {priority, ""} -> {:ok, Map.get(attrs, "blocks_on", []), priority}
      _invalid -> {:error, "frontmatter `priority` must be an integer"}
    end
  end
end
