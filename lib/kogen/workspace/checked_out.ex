defmodule Kogen.Workspace.CheckedOut do
  @moduledoc false

  alias Kogen.Workspace.Git

  @type warning :: %{path: Path.t(), detail: String.t()}

  @doc "Lists the worktrees of `origin` that have `branch` checked out."
  @spec worktrees(Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, [Path.t()]} | {:error, term()}
  def worktrees(origin, branch, git_env) do
    case Git.run(origin, ["worktree", "list", "--porcelain"], git_env) do
      {:ok, 0, output} -> {:ok, checked_out_paths(output, branch)}
      {:ok, _status, _output} -> {:error, :git_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Moves each checkout of the landed branch from `old_sha` to `new_sha`, or reports
  a warning and leaves it untouched when that could discard local changes.
  """
  @spec update([Path.t()], String.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          [warning()]
  def update(paths, branch, old_sha, new_sha, git_env) do
    for path <- paths, :ok != update_one(path, old_sha, new_sha, git_env) do
      %{path: path, detail: warning_text(branch, path, new_sha)}
    end
  end

  @spec warning_text(String.t(), Path.t(), String.t()) :: String.t()
  def warning_text(branch, path, sha) do
    "landed #{sha} on #{branch}; your checkout at #{path} has local changes and was not " <>
      "updated; run `git reset --keep #{sha}`, or merge it yourself"
  end

  @spec update_one(Path.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  defp update_one(path, old_sha, new_sha, git_env) do
    with true <- File.dir?(path) || {:error, :missing_checkout},
         :ok <- index_matches(path, old_sha, git_env),
         :ok <- files_clean(path, git_env),
         {:ok, 0, _output} <-
           Git.run(path, ["read-tree", "-u", "-m", old_sha, new_sha], git_env) do
      :ok
    else
      {:ok, _status, _output} -> {:error, :conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec index_matches(Path.t(), String.t(), %{String.t() => String.t()}) :: :ok | {:error, term()}
  defp index_matches(path, old_sha, git_env) do
    case Git.run(path, ["diff-index", "--cached", "--quiet", old_sha], git_env) do
      {:ok, 0, _output} -> :ok
      {:ok, _status, _output} -> {:error, :staged_changes}
      {:error, reason} -> {:error, reason}
    end
  end

  # Compare files with the index, which still describes old_sha after the branch CAS.
  # A status against HEAD would mistake every newly landed change for a local edit.
  defp files_clean(path, git_env) do
    with {:ok, 0, _output} <- Git.run(path, ["diff-files", "--quiet"], git_env),
         {:ok, 0, ""} <- Git.run(path, ["ls-files", "--others", "--exclude-standard"], git_env) do
      :ok
    else
      {:ok, _status, _output} -> {:error, :local_changes}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec checked_out_paths(binary(), String.t()) :: [Path.t()]
  defp checked_out_paths(output, branch) do
    expected = "branch refs/heads/#{branch}"

    for block <- String.split(output, "\n\n", trim: true),
        lines = String.split(block, "\n", trim: true),
        expected in lines,
        "worktree " <> path <- lines do
      path
    end
  end
end
