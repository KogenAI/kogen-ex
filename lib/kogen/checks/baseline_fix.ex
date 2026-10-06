defmodule Kogen.Checks.BaselineFix do
  @moduledoc false

  alias Kogen.Workspace

  def ruby?(spec) do
    String.starts_with?(spec.name, "fix/") and
      Enum.any?(spec.argv, &(Path.basename(&1) in ["rubocop", "standardrb"]))
  end

  # Undo only writes the formatter also made on the base, restoring the Candidate's
  # pre-format bytes. Corrections in other files remain part of the Candidate.
  def run(workdir, env, spec, baseline, run) do
    paths = if ruby?(spec), do: recorded_paths(spec.name, baseline), else: []

    if paths == [] do
      run.()
    else
      with {:ok, tree} <- Workspace.tree_hash(workdir, env),
           result = run.(),
           {:ok, changed} <- Workspace.changed_paths(workdir, tree, env),
           restore = Enum.filter(changed, &(&1 in paths)),
           :ok <- restore(workdir, tree, restore, env) do
        result
      end
    end
  end

  defp recorded_paths(name, baseline) do
    baseline
    |> Enum.filter(&(&1.name == name))
    |> Enum.flat_map(& &1.findings)
    |> Enum.filter(&(&1.tool == "check" and &1.id == "tree_mutated"))
    |> Enum.map(& &1.path)
  end

  defp restore(_workdir, _tree, [], _env), do: :ok

  defp restore(workdir, tree, paths, env),
    do: Workspace.restore_check_tree(workdir, tree, paths, env)
end
