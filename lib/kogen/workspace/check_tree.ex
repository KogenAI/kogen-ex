defmodule Kogen.Workspace.CheckTree do
  @moduledoc false

  alias Kogen.Workspace.Checkout
  alias Kogen.Workspace.Git

  @spec restore(Path.t(), String.t(), [String.t()], map()) :: :ok | {:error, term()}
  def restore(workdir, tree, paths, env) do
    result =
      Checkout.with_private_index(workdir, env, fn index_env ->
        with {:ok, _output} <-
               Git.status_ok(Git.run(workdir, ["read-tree", tree], index_env), :git_failed) do
          case restore_paths(workdir, tree, paths, index_env) do
            :ok -> {:ok, :restored}
            {:error, reason} -> {:error, reason}
          end
        end
      end)

    case result do
      {:ok, :restored} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_paths(workdir, tree, paths, env) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case restore_path(workdir, tree, path, env) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp restore_path(workdir, tree, path, env) do
    with true <- Git.safe_relative_path?(path),
         {:ok, 0, present} <- Git.run(workdir, ["ls-tree", "-z", tree, "--", path], env) do
      if present == "" do
        Git.remove_if_present(Path.join(workdir, path))
      else
        case Git.status_ok(
               Git.run(workdir, ["restore", "--worktree", "--source", tree, "--", path], env),
               :git_failed
             ) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    else
      false -> {:error, :invalid_path}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :git_failed}
    end
  end
end
