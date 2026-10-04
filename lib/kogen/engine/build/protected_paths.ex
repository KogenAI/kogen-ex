defmodule Kogen.Engine.Build.ProtectedPaths do
  @moduledoc false

  alias Kogen.Engine.Build.Session
  alias Kogen.State.Approval
  alias Kogen.Workspace

  @spec restore(Session.t()) :: {:ok, [String.t()]} | {:error, term()}
  def restore(%Session{} = session) do
    session.approval.protected_manifest
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {path, approved_sha}, {:ok, changed} ->
      case changed?(session.workdir, path, approved_sha) do
        {:ok, false} ->
          {:cont, {:ok, changed}}

        {:ok, true} ->
          with {:ok, bytes} <- approved_bytes(session, path),
               :ok <- write_approved_bytes(session.workdir, path, bytes) do
            {:cont, {:ok, [path | changed]}}
          else
            {:error, reason} -> {:halt, {:error, {path, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {path, reason}}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      error -> error
    end
  end

  defp changed?(root, path, approved_sha) do
    with :ok <- validate_path(path),
         {:ok, parents} <- parent_state(root, path) do
      case parents do
        :missing -> {:ok, true}
        :present -> target_changed?(Path.join(root, path), approved_sha)
      end
    end
  end

  defp target_changed?(path, approved_sha) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, bytes} -> {:ok, sha256(bytes) != approved_sha}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _other_type} ->
        {:ok, true}

      {:error, :enoent} ->
        {:ok, true}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp approved_bytes(%Session{approval: %Approval{} = approval} = session, path) do
    intent_path = ".kogen/intents/#{approval.slug}/intent.md"
    acceptance_path = ".kogen/acceptance/#{approval.slug}_test.exs"
    candidate_path = "test/acceptance/#{approval.slug}_test.exs"

    case path do
      ^intent_path ->
        {:ok, approval.intent_bytes}

      ^acceptance_path ->
        acceptance_bytes(approval, acceptance_path)

      ^candidate_path ->
        acceptance_bytes(approval, acceptance_path)

      other ->
        Workspace.read_file_at(session.request.origin, session.base_sha, other, session.git_env)
    end
  end

  defp acceptance_bytes(%Approval{acceptance_files: files}, path) do
    case Map.fetch(files, path) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :approved_acceptance_bytes_missing}
    end
  end

  defp write_approved_bytes(root, path, bytes) do
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

  defp parent_state(root, path) do
    path
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.reduce_while({:ok, Path.expand(root), :present}, fn part, {:ok, current, :present} ->
      next = Path.join(current, part)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, {:ok, next, :present}}
        {:ok, _other_type} -> {:halt, {:error, {:unsafe_parent, next}}}
        {:error, :enoent} -> {:halt, {:ok, next, :missing}}
        {:error, reason} -> {:halt, {:error, {:stat_failed, next, reason}}}
      end
    end)
    |> case do
      {:ok, _parent, state} -> {:ok, state}
      error -> error
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

  defp validate_path(path) do
    if is_binary(path) and Path.type(path) == :relative and
         Enum.all?(Path.split(path), &(&1 not in ["", ".", "..", ".git"])) do
      :ok
    else
      {:error, :unsafe_path}
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
