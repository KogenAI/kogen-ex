defmodule Kogen.Workspace.ApprovalManifest do
  @moduledoc false

  alias Kogen.Workspace

  @spec unchanged_between(Path.t(), String.t(), String.t(), map(), map()) ::
          :ok | {:error, term()}
  def unchanged_between(origin, approved_sha, current_sha, manifest, git_env) do
    manifest
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      with {:ok, approved_file} <- file_at(origin, approved_sha, path, git_env),
           {:ok, current_file} <- file_at(origin, current_sha, path, git_env) do
        if approved_file == current_file do
          {:cont, :ok}
        else
          {:halt, {:error, {:approved_protected_file_changed, path}}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp file_at(origin, revision, path, git_env) do
    case Workspace.read_file_at(origin, revision, path, git_env) do
      {:ok, bytes} -> {:ok, {:present, bytes}}
      {:error, :missing} -> {:ok, :missing}
      {:error, reason} -> {:error, reason}
    end
  end
end
