defmodule Kogen.Queue.Lock do
  @moduledoc """
  One drain per project. `queue.pid` next to the run journals holds the draining OS process;
  a lock whose process is dead is taken over. `queue.stop` asks the drain to stop after its
  current Build.
  """

  alias Kogen.Queue.Liveness

  @spec acquire(Path.t()) :: :ok | {:running, pos_integer()} | {:error, term()}
  def acquire(state_root), do: acquire(state_root, 2)

  @spec release(Path.t()) :: :ok
  def release(state_root) do
    if read_pid(state_root) == {:ok, own_pid()} do
      _ = File.rm(pid_path(state_root))
      _ = File.rm(stop_path(state_root))
    end

    :ok
  end

  @spec state(Path.t()) :: {:running, pos_integer()} | :stopped | {:error, term()}
  def state(state_root) do
    case read_pid(state_root) do
      {:ok, nil} ->
        :stopped

      {:ok, pid} ->
        case Liveness.alive?(pid, existing_dir(state_root)) do
          {:ok, true} -> {:running, pid}
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

  defp acquire(_state_root, 0), do: {:error, :queue_lock_contended}

  defp acquire(state_root, attempts) do
    with :ok <- File.mkdir_p(state_root) do
      case File.open(pid_path(state_root), [:write, :exclusive]) do
        {:ok, file} ->
          IO.write(file, "#{own_pid()}\n")
          File.close(file)
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
    case state(state_root) do
      {:running, pid} ->
        {:running, pid}

      :stopped ->
        _ = File.rm(pid_path(state_root))
        acquire(state_root, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A missing or unparsable lock file means no drain holds the lock.
  defp read_pid(state_root) do
    case File.read(pid_path(state_root)) do
      {:ok, contents} -> {:ok, parse_pid(contents)}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, {:queue_lock_failed, reason}}
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
  defp stop_path(state_root), do: Path.join(state_root, "queue.stop")
end
