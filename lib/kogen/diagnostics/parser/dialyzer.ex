defmodule Kogen.Diagnostics.Parser.Dialyzer do
  @moduledoc false
  import Kogen.Diagnostics.Parser.Common,
    only: [location: 1, normalize_path: 2, finding: 5, lines: 1, cli_line: 1, symbol: 1]

  def findings(output, workdir) do
    output
    |> lines()
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      case diagnostic_location(cli_line(line)) do
        {:ok, path, line_number, col, rule} ->
          explanation = diagnostic_message(output, index, rule)

          message =
            explanation |> String.split("\n", trim: true) |> Enum.take(2) |> Enum.join(" ")

          [
            "dialyzer"
            |> finding(rule, {path, line_number, col}, symbol(explanation), message)
            |> Map.put(:path, normalize_path(path, workdir))
            |> Map.put(:explanation, explanation)
          ]

        :error ->
          []
      end
    end)
  end

  defp diagnostic_location(line) do
    case location(line) do
      {:ok, path, line_number, col, tail} when tail != "" ->
        rule = String.trim(tail)

        if Regex.match?(~r/^[a-z][a-z0-9_]*$/, rule),
          do: {:ok, path, line_number, col, rule},
          else: :error

      _other ->
        :error
    end
  end

  defp diagnostic_message(output, index, rule) do
    output
    |> lines()
    |> Enum.drop(index + 1)
    |> Enum.take_while(fn line ->
      clean = cli_line(line)

      diagnostic_location(clean) == :error and
        not Regex.match?(~r/^_{3,}|^done |^Halting VM|^make(?:\[\d+\])?:|Total errors:/, clean)
    end)
    |> Enum.map_join("\n", &cli_line/1)
    |> String.trim()
    |> then(fn text -> if text == "", do: rule, else: text end)
  end
end
