defmodule Kogen.Kernel.Base do
  @moduledoc false

  @spec effective(String.t() | nil, String.t() | nil, Path.t(), Path.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def effective("", configured, project, origin, git_env),
    do: effective(nil, configured, project, origin, git_env)

  def effective(explicit, _configured, _project, _origin, _git_env)
      when is_binary(explicit) and explicit != "", do: {:ok, explicit}

  def effective(nil, configured, project, origin, git_env) do
    if is_binary(configured) and configured != "",
      do: {:ok, configured},
      else: branch_from(origin, project, git_env)
  end

  defp branch_from(origin, project, git_env) do
    if Path.expand(origin) == Path.expand(project) do
      case Kogen.Workspace.remote_head_branch(project, "origin") do
        {:ok, branch} -> {:ok, branch}
        {:error, _reason} -> Kogen.Workspace.head_branch(project, git_env)
      end
    else
      case Kogen.Workspace.head_branch(origin, git_env) do
        {:ok, branch} -> {:ok, branch}
        {:error, _reason} -> Kogen.Workspace.head_branch(project, git_env)
      end
    end
  end
end
