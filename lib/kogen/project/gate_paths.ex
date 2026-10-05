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
