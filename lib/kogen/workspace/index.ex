defmodule Kogen.Workspace.Index do
  @moduledoc false

  alias Kogen.Workspace.Git

  @spec tracked_paths(Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, [String.t()]} | {:error, term()}
  def tracked_paths(repo, pathspec, git_env) do
    if Git.safe_relative_path?(pathspec) do
      case Git.run(repo, ["ls-files", "-z", "--", pathspec], git_env) do
        {:ok, 0, output} -> {:ok, Git.nul_lines(output)}
        {:ok, _status, _output} -> {:error, :git_failed}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_path}
    end
  end
end
