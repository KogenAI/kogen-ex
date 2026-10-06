defmodule Kogen.Diagnostics.Ruby do
  @moduledoc false

  alias Kogen.Diagnostics.Parser.Common

  @spec findings(binary(), String.t(), Path.t()) :: [Kogen.Contracts.Finding.t()]
  def findings(output, "minitest", root) do
    output
    |> String.split(~r/(?:^|\n)\s*(?:\d+\)\s*)?(?:Failure|Error):\s*\n/)
    |> Enum.drop(1)
    |> Enum.flat_map(&test_finding(&1, root))
  end

  def findings(output, tool, root) do
    ~r/^([^\n]+):(\d+):(\d+):\s*(?:[CWEF]:\s*)?(?:\[Correct(?:able|ed)\]\s*)?([\w\/]+):\s*(.+)$/m
    |> Regex.scan(output, capture: :all_but_first)
    |> Enum.map(fn [path, line, col, rule, message] ->
      Common.finding(
        tool,
        rule,
        {Common.normalize_path(String.trim(path), root), String.to_integer(line),
         String.to_integer(col)},
        nil,
        message
      )
    end)
  end

  defp test_finding(block, root) do
    case Regex.run(~r/([\w:]+#test_[^\s\[]+)/, block, capture: :all_but_first) do
      [name] ->
        location =
          case Regex.run(~r/([^\s\[\]]+\.rb):(\d+)/, block, capture: :all_but_first) do
            [path, line] -> {Common.normalize_path(path, root), String.to_integer(line), nil}
            nil -> {nil, nil, nil}
          end

        [%{Common.finding("minitest", "failure", location, name, block) | explanation: block}]

      nil ->
        []
    end
  end
end
