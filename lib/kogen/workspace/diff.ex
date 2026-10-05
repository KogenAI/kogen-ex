defmodule Kogen.Workspace.Diff do
  @moduledoc false

  alias Kogen.Workspace.Checkout
  alias Kogen.Workspace.Git

  @spec diff(Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, binary()} | {:error, term()}
  def diff(path, base_sha, git_env), do: diff_internal(path, base_sha, [], git_env, false)

  @spec diff_excluding(Path.t(), String.t(), [String.t()], %{String.t() => String.t()}) ::
          {:ok, binary()} | {:error, term()}
  def diff_excluding(path, base_sha, excluded_paths, git_env) do
    diff_internal(path, base_sha, excluded_paths, git_env, true)
  end

  defp diff_internal(path, base_sha, excluded_paths, git_env, binary?) do
    if Git.valid_worktree_path?(path) and Checkout.valid_sha?(base_sha) do
      if Enum.all?(excluded_paths, &Git.safe_relative_path?/1) do
        Checkout.with_private_index(
          path,
          git_env,
          &tree_diff(path, base_sha, excluded_paths, binary?, &1)
        )
      else
        {:error, :invalid_excluded_paths}
      end
    else
      {:error, :invalid_path}
    end
  end

  defp tree_diff(path, base_sha, excluded_paths, binary?, index_env) do
    with {:ok, _output} <- git_ok(path, ["read-tree", "HEAD"], index_env),
         {:ok, _output} <- git_ok(path, ["add", "-A", "--", "."], index_env),
         {:ok, tree} <- git_ok(path, ["write-tree"], index_env) do
      # Git.run reads the full log; keep the patch out of the bounded Proc output tail.
      binary_option = if binary?, do: ["--binary"], else: []

      pathspecs =
        if binary?, do: ["--", "." | Enum.map(excluded_paths, &exclude_pathspec/1)], else: []

      git_ok(
        path,
        [
          "diff"
          | binary_option ++
              ["--no-ext-diff", "--no-textconv", "--no-color", base_sha, Git.trim_line(tree)] ++
              pathspecs
        ],
        index_env
      )
    end
  end

  defp exclude_pathspec(path), do: ":(top,literal,exclude)#{path}"

  defp git_ok(path, argv, git_env), do: Git.status_ok(Git.run(path, argv, git_env), :git_failed)
end
