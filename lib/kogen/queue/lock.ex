defmodule Kogen.Queue.Lock do
  @moduledoc """
  One drain per project. `queue.pid` next to the run journals holds the draining OS process;
  a lock whose process is dead is taken over. `queue.stop` asks the drain to stop after its
  current Build.
  """

  alias Kogen.Queue.Liveness

  @spec acquire(Path.t()) :: :ok | {:running, pos_integer()} | {:error, term()}
  def acquire(state_root) do
    case acquire_with_owner(state_root) do
      {:running, %{pid: pid}} -> {:running, pid}
      result -> result
    end
  end

  @doc "Acquires the queue lock or returns the current live owner's persisted metadata."
  @spec acquire_with_owner(Path.t()) ::
          :ok | {:running, %{pid: pos_integer(), started_at: String.t() | nil}} | {:error, term()}
  def acquire_with_owner(state_root), do: do_acquire(state_root, 2)

  @spec release(Path.t()) :: :ok
  def release(state_root) do
    owner_pid = own_pid()

    case read_owner(state_root) do
      {:ok, %{pid: ^owner_pid}} ->
        _ = File.rm(started_path(state_root))
        _ = File.rm(stop_path(state_root))
        _ = File.rm(pid_path(state_root))

      _other ->
        :ok
    end

    :ok
  end

  @spec state(Path.t()) :: {:running, pos_integer()} | :stopped | {:error, term()}
  def state(state_root) do
    case owner_state(state_root) do
      {:running, %{pid: pid}} -> {:running, pid}
      other -> other
    end
  end

  @doc "Returns the live queue owner's PID and persisted start time, if any."
  @spec owner_state(Path.t()) ::
          {:running, %{pid: pos_integer(), started_at: String.t() | nil}}
          | :stopped
          | {:error, term()}
  def owner_state(state_root) do
    case read_owner(state_root) do
      {:ok, %{pid: nil}} ->
        :stopped

      {:ok, %{pid: pid, started_at: started_at}} ->
        case Liveness.alive?(pid, existing_dir(state_root)) do
          {:ok, true} -> {:running, %{pid: pid, started_at: started_at}}
          {:ok, false} -> :stopped
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec request_stop(Path.t()) :: {:stopping, pos_integer()} | :not_running | {:error, term()}
  def request_stop(state_root) do
    case state(state_root) do
      {:running, pid} ->
        case File.write(stop_path(state_root), "stop\n") do
          :ok -> {:stopping, pid}
          {:error, reason} -> {:error, {:queue_stop_failed, reason}}
        end

      :stopped ->
        :not_running

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec stop_requested?(Path.t()) :: boolean()
  def stop_requested?(state_root), do: File.exists?(stop_path(state_root))

  @spec log_path(Path.t()) :: Path.t()
  def log_path(state_root), do: Path.join(state_root, "queue.log")

  defp do_acquire(_state_root, 0), do: {:error, :queue_lock_contended}

  defp do_acquire(state_root, attempts) do
    with :ok <- File.mkdir_p(state_root) do
      case File.open(pid_path(state_root), [:write, :exclusive]) do
        {:ok, file} ->
          owner_pid = own_pid()
          IO.write(file, "#{owner_pid}\n")
          File.close(file)

          started_at =
            :microsecond
            |> System.system_time()
            |> DateTime.from_unix!(:microsecond)
            |> DateTime.to_iso8601()

          _ = File.write(started_path(state_root), "#{owner_pid}\n#{started_at}\n")
          _ = File.rm(stop_path(state_root))
          :ok

        {:error, :eexist} ->
          take_over(state_root, attempts)

        {:error, reason} ->
          {:error, {:queue_lock_failed, reason}}
      end
    end
  end

  defp take_over(state_root, attempts) do
    case owner_state(state_root) do
      {:running, owner} ->
        {:running, owner}

      :stopped ->
        _ = File.rm(pid_path(state_root))
        _ = File.rm(started_path(state_root))
        do_acquire(state_root, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Missing or unparsable PID data means no drain holds the lock. PID-only legacy files
  # use their persisted file modification time as the best available start-time metadata.
  defp read_owner(state_root) do
    path = pid_path(state_root)

    case File.read(path) do
      {:ok, contents} ->
        [pid_text | _rest] = String.split(contents, "\n", parts: 2)
        pid = parse_pid(pid_text)

        with {:ok, started_at} <- owner_started_at(pid, path, state_root) do
          {:ok, %{pid: pid, started_at: started_at}}
        end

      {:error, :enoent} ->
        {:ok, %{pid: nil, started_at: nil}}

      {:error, reason} ->
        {:error, {:queue_lock_failed, reason}}
    end
  end

  defp owner_started_at(nil, _pid_path, _state_root), do: {:ok, nil}

  defp owner_started_at(pid, pid_path, state_root) do
    case File.read(started_path(state_root)) do
      {:ok, contents} ->
        case String.split(contents, "\n", parts: 3) do
          [owner_pid, value | _rest] ->
            value = String.trim(value)

            if parse_pid(owner_pid) == pid and valid_timestamp?(value),
              do: {:ok, value},
              else: file_started_at(pid_path)

          _malformed ->
            file_started_at(pid_path)
        end

      {:error, :enoent} ->
        file_started_at(pid_path)

      {:error, reason} ->
        {:error, {:queue_lock_failed, reason}}
    end
  end

  defp valid_timestamp?(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp file_started_at(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        started_at = mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_iso8601()
        {:ok, started_at}

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:queue_lock_failed, reason}}
    end
  end

  defp parse_pid(contents) do
    case Integer.parse(String.trim(contents)) do
      {pid, ""} when pid > 0 -> pid
      _invalid -> nil
    end
  end

  defp existing_dir(state_root), do: if(File.dir?(state_root), do: state_root, else: "/")

  defp own_pid, do: String.to_integer(System.pid())

  defp pid_path(state_root), do: Path.join(state_root, "queue.pid")
  defp started_path(state_root), do: Path.join(state_root, "queue.started")
  defp stop_path(state_root), do: Path.join(state_root, "queue.stop")
end
