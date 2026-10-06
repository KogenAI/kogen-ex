defmodule Kogen.Quality.Mutation.Plan do
  @moduledoc false
  alias Kogen.Quality.Process, as: Command

  @operators %{
    ==: "!=",
    !=: "==",
    >: ">=",
    <: "<=",
    >=: ">",
    <=: "<",
    +: "-",
    -: "+",
    and: "or",
    or: "and"
  }

  @spec build(struct(), [Path.t()]) :: {:ok, [map()]} | {:error, term()}
  def build(request, paths) do
    with {:ok, diff} <-
           Command.run(
             request,
             ["git", "diff", "--no-ext-diff", "--unified=0", request.base, "--", "lib"],
             request.workdir
           ) do
      changed = changed_lines(diff)

      Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
        case mutants(request.workdir, path, lines(request, changed, path)) do
          {:ok, found} -> {:cont, {:ok, acc ++ found}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp lines(request, changed, path) do
    case Map.fetch(changed, path) do
      {:ok, lines} ->
        lines

      :error ->
        if File.exists?(Path.join(request.baseline, path)) do
          MapSet.new()
        else
          case File.read(Path.join(request.workdir, path)) do
            {:ok, text} -> MapSet.new(1..length(String.split(text, "\n")))
            _ -> MapSet.new()
          end
        end
    end
  end

  defp changed_lines(diff) do
    {_, result} =
      diff
      |> String.split("\n")
      |> Enum.reduce({nil, %{}}, fn line, {path, acc} ->
        cond do
          String.starts_with?(line, "+++ b/") ->
            {String.replace_prefix(line, "+++ b/", ""), acc}

          String.starts_with?(line, "@@ ") and path != nil ->
            set_hunk(path, line, acc)

          true ->
            {path, acc}
        end
      end)

    result
  end

  defp set_hunk(path, line, acc) do
    case Regex.run(~r/\+(\d+)(?:,(\d+))? @@/, line) do
      [_, first | count] ->
        start = String.to_integer(first)

        size =
          case count do
            [n] when n != "" -> String.to_integer(n)
            _ -> 1
          end

        lines = if size == 0, do: [], else: Enum.to_list(start..(start + size - 1))
        {path, Map.update(acc, path, MapSet.new(lines), &MapSet.union(&1, MapSet.new(lines)))}

      _ ->
        {path, acc}
    end
  end

  defp mutants(root, path, lines) do
    if String.starts_with?(path, "lib/") and Path.extname(path) == ".ex" do
      case read_ast(Path.join(root, path)) do
        {:ok, ast} ->
          {_, found} = Macro.prewalk(ast, [], &collect(&1, &2, path, lines))

          {:ok, Enum.sort_by(found, &{&1.path, &1.line, &1.column})}

        {:error, reason} ->
          {:error, {:unparseable_source, path, reason}}
      end
    else
      {:ok, []}
    end
  end

  defp read_ast(path) do
    with {:ok, source} <- File.read(path), do: Code.string_to_quoted(source, columns: true)
  end

  defp collect({op, meta, [_, _]} = node, acc, path, lines) when is_map_key(@operators, op) do
    if MapSet.member?(lines, meta[:line]) do
      item = %{
        path: path,
        line: meta[:line],
        column: meta[:column],
        original: Atom.to_string(op),
        replacement: Map.fetch!(@operators, op)
      }

      {node, [item | acc]}
    else
      {node, acc}
    end
  end

  defp collect(node, acc, _path, _lines), do: {node, acc}

  @spec apply(binary(), map()) :: binary()
  def apply(source, item) do
    source
    |> String.split("\n")
    |> List.update_at(item.line - 1, fn line ->
      {before, rest} = String.split_at(line, item.column - 1)

      if String.starts_with?(rest, item.original),
        do: before <> item.replacement <> String.replace_prefix(rest, item.original, ""),
        else: line
    end)
    |> Enum.join("\n")
  end
end
