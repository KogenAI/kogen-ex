defmodule Kogen.Workspace.BaseGlob do
  @moduledoc false

  @doc "Expands patterns against the regular files of a checkout."
  @spec checkout(Path.t(), [String.t()]) :: [String.t()]
  def checkout(root, patterns), do: Enum.flat_map(patterns, &expand(root, &1))

  @doc """
  Evaluates the patterns with the checkout's glob semantics by matching them against an
  empty-file skeleton of the base tree.
  """
  @spec tree([String.t()], [String.t()], Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def tree(base_paths, patterns, tmp_dir) do
    root = Path.join(tmp_dir, "kogen-approval-#{System.unique_integer([:positive])}")

    try do
      with :ok <- File.mkdir_p(root),
           :ok <- touch_all(root, base_paths) do
        {:ok, checkout(root, patterns)}
      else
        {:error, reason} -> {:error, {:base_tree_unavailable, reason}}
      end
    after
      File.rm_rf(root)
    end
  end

  defp expand(root, pattern) do
    root
    |> Path.join(pattern)
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp touch_all(root, paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      target = Path.join(root, path)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(target, "") do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
