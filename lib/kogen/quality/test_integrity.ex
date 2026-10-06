defmodule Kogen.Quality.TestIntegrity do
  @moduledoc "Advisory inventory of test assertions tied to implementation text."
  alias Kogen.Quality.Report

  @spec findings([{Path.t(), Macro.t()}]) :: [map()]
  def findings(sources) do
    for {path, ast} <- sources,
        String.ends_with?(path, "_test.exs"),
        line <- coupled_assertions(ast) do
      Report.finding(
        "test_integrity",
        "implementation_text",
        path,
        line,
        "This assertion may pin implementation spelling. Execute the interface and check its " <>
          "result; keep byte comparisons only for custody or delivery. Inventory is heuristic."
      )
    end
  end

  defp coupled_assertions(ast) do
    {_, lines} =
      Macro.prewalk(ast, [], fn
        {name, meta, [expression | _]} = node, lines when name in [:assert, :refute] ->
          if source_match?(expression),
            do: {node, [meta[:line] || 1 | lines]},
            else: {node, lines}

        node, lines ->
          {node, lines}
      end)

    Enum.uniq(lines)
  end

  defp source_match?(expression) do
    {_, coupled} =
      Macro.prewalk(expression, false, fn
        {:=~, _, [left, _]} = node, acc -> {node, acc or source_read?(left)}
        node, acc -> {node, acc}
      end)

    coupled
  end

  defp source_read?(expression) do
    {_, found} =
      Macro.prewalk(expression, false, fn
        {{:., _, [{:__aliases__, _, [:File]}, name]}, _, args} = node, acc
        when name in [:read, :read!] ->
          {node, acc or source_path?(args)}

        {name, _, context} = node, acc when is_atom(context) ->
          {node, acc or name in [:source, :local]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp source_path?(args) do
    {_, found} =
      Macro.prewalk(args, false, fn
        value, acc when is_binary(value) -> {value, acc or String.ends_with?(value, ".ex")}
        node, acc -> {node, acc}
      end)

    found
  end
end
