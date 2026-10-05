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
          case restore_path(session, path, approved_sha) do
            :ok -> {:cont, {:ok, [path | changed]}}
            {:error, reason} -> {:halt, {:error, {path, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {path, reason}}}
      end
    end)
    |> case do
      {:ok, paths} -> clean_acceptance_source(session, paths)
      error -> error
    end
  end

  defp restore_path(session, path, approved_sha) do
    if approved_sha == Workspace.absent_digest() do
      with :ok <- validate_path(path),
           {:ok, _removed} <- File.rm_rf(Path.join(session.workdir, path)) do
        :ok
      end
    else
      with {:ok, bytes} <- approved_bytes(session, path),
           :ok <- ensure_consistent(session, path, bytes, approved_sha) do
        Workspace.write_file(session.workdir, path, bytes)
      end
    end
  end

  defp clean_acceptance_source(session, paths) do
    case Workspace.remove_acceptance_source(session.workdir, session.approval.slug) do
      {:ok, nil} ->
        {:ok, Enum.reverse(paths)}

      {:ok, path} ->
        {:ok, Enum.reverse([path | paths])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp changed?(root, path, approved_sha) do
    with :ok <- validate_path(path),
         {:ok, parents} <- parent_state(root, path) do
      case parents do
        :missing -> {:ok, approved_sha != Workspace.absent_digest()}
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
        {:ok, approved_sha != Workspace.absent_digest()}

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

  # Non-Intent protected paths are approved from the base tree, so restoring bytes that hash
  # differently would corrupt the Candidate; report a controller bug instead of writing them.
  defp ensure_consistent(%Session{approval: approval} = session, path, bytes, approved_sha) do
    if intent_path?(approval.slug, path) or sha256(bytes) == approved_sha do
      :ok
    else
      {:error,
       {:controller_bug,
        "approved bytes of #{path} differ from the base tree at #{session.base_sha}; " <>
          "the approval manifest is inconsistent with its base"}}
    end
  end

  defp intent_path?(slug, path),
    do: path in [".kogen/intents/#{slug}/intent.md", "test/acceptance/#{slug}_test.exs"]

  defp acceptance_bytes(%Approval{acceptance_files: files}, path) do
    case Map.fetch(files, path) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :approved_acceptance_bytes_missing}
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
