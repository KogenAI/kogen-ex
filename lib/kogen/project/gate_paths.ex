defmodule Kogen.Project.GatePaths do
  @moduledoc """
  The files that define a project's gate: `.kogen/project.yaml`, the config files the project
  declares under `gate_paths`, and any tracked file named in a check, fix or diagnose command.

  They are protected from Builder edits unless the Intent declares `changes_gate: true`.
  """

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project

  @definition ".kogen/project.yaml"
  @interpreters ~w(sh bash zsh dash python python3 ruby node perl elixir escript)
  @path_token ~r/(?<![\w.\/-])(?:\.\/)?[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.?*{}\[\]-]+)*(?:\/)?(?![\w.\/-])/

  @doc "The gate paths that `changes_gate: true` releases from Build protection."
  @spec effective(Project.t()) :: [String.t()]
  def effective(%Project{} = project) do
    existing_commands =
      project
      |> command_argv()
      |> Enum.flat_map(&program_files/1)
      |> Enum.map(&String.replace_prefix(&1, "./", ""))
      |> Enum.uniq()
      |> Enum.filter(&File.regular?(Path.join(project.root, &1)))

    Enum.uniq([@definition | project.gate_paths] ++ command_files(project, existing_commands))
  end

  @doc "Returns the first repository-relative path token in `text` that matches a gate path."
  @spec referenced_path([String.t()], String.t()) :: String.t() | nil
  def referenced_path(paths, text) when is_list(paths) and is_binary(text) do
    candidates =
      @path_token
      |> Regex.scan(text)
      |> Enum.map(&(&1 |> hd() |> normalize_reference()))

    Enum.find_value(paths, fn path ->
      Enum.find(candidates, &matches_gate_path?(&1, path))
    end)
  end

  @doc """
  The patterns the Builder may not edit. Declared `protected_paths` always apply; the gate's
  own files apply unless the Intent declares `changes_gate`. Command files are only those
  already tracked in `tracked_paths`.
  """
  @spec protected_patterns(Project.t(), boolean(), [String.t()]) :: [String.t()]
  def protected_patterns(%Project{} = project, true, _tracked_paths), do: project.protected_paths

  def protected_patterns(%Project{} = project, false, tracked_paths) do
    Enum.uniq(
      project.protected_paths ++
        [@definition | project.gate_paths] ++ command_files(project, tracked_paths)
    )
  end

  @doc "Patterns that name one file which must stay absent when the base tree lacks it."
  @spec absent_candidates([String.t()], [String.t()]) :: [String.t()]
  def absent_candidates(patterns, tracked_paths) do
    Enum.filter(patterns, fn pattern ->
      not String.contains?(pattern, ["*", "?", "[", "{"]) and
        not String.ends_with?(pattern, "/") and
        not Enum.any?(tracked_paths, &(&1 == pattern or String.starts_with?(&1, pattern <> "/")))
    end)
  end

  defp normalize_reference(path) do
    path
    |> String.replace_prefix("./", "")
    |> String.trim_trailing("/")
    |> String.trim_trailing(".")
  end

  defp matches_gate_path?(candidate, configured) do
    path = String.replace_prefix(configured, "./", "")

    cond do
      glob_pattern?(path) ->
        Regex.match?(compile_glob(path), candidate)

      String.ends_with?(path, "/") ->
        directory = String.trim_trailing(path, "/")
        candidate == directory or String.starts_with?(candidate, directory <> "/")

      true ->
        candidate == path
    end
  end

  defp glob_pattern?(path), do: String.contains?(path, ["*", "?", "[", "{"])

  defp compile_glob(path) do
    source = "\\A" <> glob_source(path, []) <> "\\z"
    Regex.compile!(source)
  end

  defp glob_source(<<>>, parts), do: parts |> Enum.reverse() |> IO.iodata_to_binary()
  defp glob_source(<<"**/", rest::binary>>, parts), do: glob_source(rest, ["(?:.*/)?" | parts])

  defp glob_source(<<"**", rest::binary>>, parts), do: glob_source(rest, [".*" | parts])
  defp glob_source(<<"*", rest::binary>>, parts), do: glob_source(rest, ["[^/]*" | parts])
  defp glob_source(<<"?", rest::binary>>, parts), do: glob_source(rest, ["[^/]" | parts])

  defp glob_source(<<"[", rest::binary>>, parts) do
    case :binary.match(rest, "]") do
      {index, 1} when index > 0 ->
        class = binary_part(rest, 0, index)
        tail = binary_part(rest, index + 1, byte_size(rest) - index - 1)
        glob_source(tail, ["[" <> class <> "]" | parts])

      _no_class ->
        glob_source(rest, ["\\[" | parts])
    end
  end

  defp glob_source(<<"{", rest::binary>>, parts) do
    case :binary.match(rest, "}") do
      {index, 1} when index > 0 ->
        alternatives =
          rest
          |> binary_part(0, index)
          |> String.split(",")
          |> Enum.map_join("|", &glob_source(&1, []))

        tail = binary_part(rest, index + 1, byte_size(rest) - index - 1)
        glob_source(tail, ["(?:" <> alternatives <> ")" | parts])

      _no_group ->
        glob_source(rest, ["\\{" | parts])
    end
  end

  defp glob_source(<<char::utf8, rest::binary>>, parts),
    do: glob_source(rest, [Regex.escape(<<char::utf8>>) | parts])

  defp glob_source(<<byte, rest::binary>>, parts),
    do: glob_source(rest, [Regex.escape(<<byte>>) | parts])

  # A command's program, or the script handed to an interpreter, is part of the gate. Other
  # arguments name the subject under test and are not.
  defp command_files(%Project{} = project, tracked_paths) do
    tracked = MapSet.new(tracked_paths)

    project
    |> command_argv()
    |> Enum.flat_map(&program_files/1)
    |> Enum.map(&String.replace_prefix(&1, "./", ""))
    |> Enum.filter(&MapSet.member?(tracked, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp program_files(["make" | _rest]), do: ["Makefile", "GNUmakefile", "makefile"]

  defp program_files([program | rest]) when program in @interpreters do
    [program | rest |> Enum.reject(&String.starts_with?(&1, "-")) |> Enum.take(1)]
  end

  defp program_files([program | _rest]), do: [program]
  defp program_files([]), do: []

  defp command_argv(%Project{} = project) do
    specs = project.checks ++ project.acceptance_checks ++ project.fix

    Enum.map(specs, fn %CheckSpec{argv: argv} -> argv end) ++
      Enum.map(project.diagnose, & &1.argv)
  end
end
