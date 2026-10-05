defmodule Kogen.Workspace.ApprovedFile do
  @moduledoc false

  @doc "Writes bytes at a path under root, replacing symlinks and directories in the way."
  @spec write(Path.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write(root, path, bytes) do
    with :ok <- ensure_parent_dirs(root, Path.split(Path.dirname(path))),
         :ok <- remove_non_file_target(Path.join(root, path)) do
      case File.write(Path.join(root, path), bytes) do
        :ok -> :ok
        {:error, reason} -> {:error, {:write_failed, reason}}
      end
    end
  end

  defp remove_non_file_target(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        file_rm(path)

      {:ok, %File.Stat{type: :directory}} ->
        case File.rm_rf(path) do
          {:ok, _removed} ->
            :ok

          {:error, reason, failed_path} ->
            {:error, {:remove_failed, failed_path, reason}}
        end

      {:ok, _other_type} ->
        file_rm(path)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:stat_failed, reason}}
    end
  end

  defp file_rm(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:remove_failed, reason}}
    end
  end

  defp ensure_parent_dirs(root, parts) do
    parts
    |> Enum.reduce_while({:ok, Path.expand(root)}, fn part, {:ok, current} ->
      next = Path.join(current, part)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :directory}} ->
          {:cont, {:ok, next}}

        {:ok, _other_type} ->
          {:halt, {:error, {:unsafe_parent, next}}}

        {:error, :enoent} ->
          case File.mkdir(next) do
            :ok -> {:cont, {:ok, next}}
            {:error, reason} -> {:halt, {:error, {:mkdir_failed, next, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:stat_failed, next, reason}}}
      end
    end)
    |> case do
      {:ok, _parent} -> :ok
      error -> error
    end
  end
end
