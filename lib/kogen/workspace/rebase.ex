defmodule Kogen.Workspace.Rebase do
  @moduledoc false

  alias Kogen.Workspace.Git

  @spec run(Path.t(), Path.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  def run(path, origin, base_sha, git_env) do
    if valid_inputs?(path, origin, base_sha) do
      with :ok <- fetch_base(path, origin, base_sha, git_env) do
        rebase_candidate(path, base_sha, git_env)
      end
    else
      {:error, :invalid_rebase}
    end
  end

  defp valid_inputs?(path, origin, base_sha) do
    Git.valid_worktree_path?(path) and is_binary(origin) and Path.type(origin) == :absolute and
      File.dir?(origin) and valid_sha?(base_sha)
  end

  defp fetch_base(path, origin, base_sha, git_env) do
    case Git.run(path, ["fetch", "--quiet", origin, base_sha], git_env) do
      {:ok, 0, _output} -> :ok
      {:ok, status, _output} -> {:error, {:git_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rebase_candidate(path, base_sha, git_env) do
    case Git.run(path, ["rebase", base_sha], git_env) do
      {:ok, 0, _output} ->
        :ok

      {:ok, status, output} ->
        conflicts(path, base_sha, git_env, status, output)

      {:error, reason} ->
        _abort = Git.run(path, ["rebase", "--abort"], git_env)
        {:error, reason}
    end
  end

  defp conflicts(path, base, git_env, status, output) do
    case Git.run(path, ["diff", "--name-only", "--diff-filter=U"], git_env) do
      {:ok, 0, paths} when paths != "" ->
        with {:ok, 0, _output} <- Git.run(path, ["rebase", "--quit"], git_env),
             {:ok, 0, _output} <- Git.run(path, ["reset", "--mixed", base], git_env) do
          {:error, {:rebase_conflict, String.split(paths, "\n", trim: true)}}
        else
          error -> {:error, {:rebase_cleanup_failed, error}}
        end

      _other ->
        _abort = Git.run(path, ["rebase", "--abort"], git_env)
        {:error, {:git_failed, status, output}}
    end
  end

  defp valid_sha?(sha) when is_binary(sha),
    do: Regex.match?(~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/, sha)

  defp valid_sha?(_sha), do: false
end
