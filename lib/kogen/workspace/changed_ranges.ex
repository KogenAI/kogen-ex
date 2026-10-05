defmodule Kogen.Workspace.ChangedRanges do
  @moduledoc false

  alias Kogen.Workspace.Checkout
  alias Kogen.Workspace.Git

  @hunk ~r/^@@ -(?<old>\d+)(?:,(?<old_count>\d+))? \+(?<new>\d+)(?:,(?<new_count>\d+))? @@/m

  @spec changed_line_ranges(Path.t(), String.t(), map()) :: {:ok, [String.t()]} | {:error, term()}
  def changed_line_ranges(workdir, base, env) do
    with {:ok, tree} <- Checkout.tree_hash(workdir, env),
         {:ok, names} <-
           git(workdir, ["diff", "--no-renames", "--name-only", "-z", base, tree], env),
         {:ok, patch} <-
           git(
             workdir,
             [
               "diff",
               "--no-renames",
               "--no-ext-diff",
               "--no-textconv",
               "--no-color",
               "--unified=0",
               base,
               tree
             ],
             env
           ) do
      blocks = patch |> String.split(~r/^diff --git /m) |> Enum.drop(1)
      entries = names |> Git.nul_lines() |> Enum.zip(blocks) |> Enum.flat_map(&ranges/1)
      {:ok, Enum.take(entries, 30)}
    end
  end

  defp ranges({path, block}) do
    path = if String.contains?(path, ["\n", "\r", "\t"]), do: inspect(path), else: path

    case Regex.scan(@hunk, block, capture: ["old", "old_count", "new", "new_count"]) do
      [] ->
        [path]

      hunks ->
        Enum.map(hunks, fn [old, old_count, new, new_count] ->
          "#{path}: base #{range(old, old_count)} -> candidate #{range(new, new_count)}"
        end)
    end
  end

  defp range(start, count) when count in ["", "0", "1"], do: start

  defp range(start, count),
    do: "#{start}-#{String.to_integer(start) + String.to_integer(count) - 1}"

  defp git(workdir, argv, env), do: Git.status_ok(Git.run(workdir, argv, env), :git_failed)
end
