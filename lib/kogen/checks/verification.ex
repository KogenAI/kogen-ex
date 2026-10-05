defmodule Kogen.Checks.Verification do
  @moduledoc false

  alias Kogen.Checks.Feedback
  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Workspace

  def verify_command(workdir, env, spec, baseline, run) do
    with {:ok, tree} <- snapshot(workdir, env, spec),
         {result, extra} <- run.(),
         {:ok, paths} <- changed_paths(workdir, tree, env) do
      assessment = Feedback.gate(result, spec, paths)

      annotated =
        CheckBaseline.annotate(assessment, if(baseline == :record, do: [], else: baseline))

      annotated =
        Map.put(
          annotated,
          :base_red?,
          annotated.base_red? or (paths == [] and Map.get(result, :base_red?, false))
        )

      with :ok <-
             restore_excused(
               workdir,
               tree,
               paths,
               env,
               annotated.base_red? or baseline == :record
             ) do
        {:ok, {annotated, extra}}
      end
    end
  end

  defp snapshot(workdir, env, spec) do
    if String.starts_with?(spec.name, "fix/") or not File.exists?(Path.join(workdir, ".git")),
      do: {:ok, nil},
      else: Workspace.tree_hash(workdir, env)
  end

  defp changed_paths(_workdir, nil, _env), do: {:ok, []}
  defp changed_paths(workdir, tree, env), do: Workspace.changed_paths(workdir, tree, env)

  defp restore_excused(_workdir, _tree, [], _env, _excused), do: :ok

  defp restore_excused(workdir, tree, paths, env, true),
    do: Workspace.restore_check_tree(workdir, tree, paths, env)

  defp restore_excused(_workdir, _tree, _paths, _env, false), do: :ok
end
