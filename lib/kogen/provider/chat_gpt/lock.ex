defmodule Kogen.Provider.ChatGPT.Lock do
  @moduledoc false

  @retry_ms 25
  @wait_ms 90_000
  @stale_ms 60_000

  @spec with_lock(Path.t(), String.t(), (-> term()), keyword()) ::
          {:ok, term()} | {:error, :lock_timeout | term()}
  def with_lock(root, name, fun, opts \\ [])
      when is_binary(root) and is_binary(name) and is_function(fun, 0) do
    lock_path = Path.join([root, "locks", name <> ".lock"])
    timeout = Keyword.get(opts, :timeout_ms, @wait_ms)

    with :ok <- File.mkdir_p(Path.dirname(lock_path)),
         {:ok, token} <- acquire(lock_path, System.monotonic_time(:millisecond) + timeout) do
      try do
        {:ok, fun.()}
      after
        release(lock_path, token)
      end
    end
  end

  defp acquire(path, deadline) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    case File.mkdir(path) do
      :ok ->
        case File.write(Path.join(path, "owner"), owner_data(token), [:binary, :exclusive]) do
          :ok ->
            {:ok, token}

          {:error, reason} ->
            File.rmdir(path)
            {:error, reason}
        end

      {:error, :eexist} ->
        contend(path, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp contend(path, deadline) do
    with {:ok, stale?} <- stale?(path) do
      if stale? do
        with :ok <- remove_stale(path), do: acquire(path, deadline)
      else
        wait(path, deadline)
      end
    end
  end

  defp wait(path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :lock_timeout}
    else
      receive do
      after
        @retry_ms -> acquire(path, deadline)
      end
    end
  end

  defp owner_data(token), do: "#{System.pid()} #{System.system_time(:millisecond)} #{token}\n"

  defp stale?(path) do
    case File.read(Path.join(path, "owner")) do
      {:ok, contents} -> owner_stale?(contents, path)
      {:error, :enoent} -> old_directory?(path)
      {:error, reason} -> {:error, reason}
    end
  end

  # A newly opened owner file can still be empty while its writer holds the lock.
  defp owner_stale?(contents, path) do
    case String.split(String.trim(contents), " ", parts: 3) do
      [_pid, created_at, _token] ->
        case Integer.parse(created_at) do
          {timestamp, ""} -> {:ok, System.system_time(:millisecond) - timestamp > @stale_ms}
          _invalid -> old_directory?(path)
        end

      _invalid ->
        old_directory?(path)
    end
  end

  defp old_directory?(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {:ok, System.system_time(:second) - stat.mtime > div(@stale_ms, 1_000)}
      {:error, :enoent} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_stale(path) do
    stale_path =
      path <> ".stale-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    case File.rename(path, stale_path) do
      :ok ->
        _ = File.rm(Path.join(stale_path, "owner"))
        _ = File.rmdir(stale_path)
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release(path, token) do
    owner = Path.join(path, "owner")

    case File.read(owner) do
      {:ok, contents} ->
        if String.ends_with?(contents, " #{token}\n") do
          File.rm(owner)
          File.rmdir(path)
        end

      _other ->
        :ok
    end
  end
end
