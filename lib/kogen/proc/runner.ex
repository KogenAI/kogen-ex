defmodule Kogen.Proc.Runner.Artifacts do
  @moduledoc false

  @enforce_keys [:log_path, :stdin_path, :remove_log, :remove_stdin]
  defstruct [:log_path, :stdin_path, :remove_log, :remove_stdin]

  @type t :: %__MODULE__{
          log_path: Path.t(),
          stdin_path: Path.t(),
          remove_log: boolean(),
          remove_stdin: boolean()
        }
end

defmodule Kogen.Proc.Runner.WireResult do
  @moduledoc false

  @enforce_keys [:exit_status, :timed_out, :exec_error]
  defstruct [:exit_status, :timed_out, :exec_error]

  @type t :: %__MODULE__{
          exit_status: integer() | nil,
          timed_out: boolean(),
          exec_error: non_neg_integer()
        }
end

defmodule Kogen.Proc.Runner do
  @moduledoc false

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc.Request
  alias Kogen.Proc.Runner.Artifacts
  alias Kogen.Proc.Runner.WireResult
  alias Kogen.Proc.Sandbox
  alias Kogen.Proc.Wrapper

  @tail_bytes 16 * 1024
  @cleanup_wait_ms 3_000

  @spec run(Request.t()) :: {:ok, ProcResult.t()} | {:error, term()}
  def run(%Request{} = request) do
    caller = self()
    result_ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn -> send(caller, {result_ref, execute(request, caller)}) end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :runner_failed}
    end
  end

  @spec execute(Request.t(), pid()) :: {:ok, ProcResult.t()} | {:error, term()}
  defp execute(request, caller) do
    started_at = System.monotonic_time(:millisecond)
    owner_monitor = Process.monitor(caller)

    result = execute_with_artifacts(request, owner_monitor, started_at)

    Process.demonitor(owner_monitor, [:flush])
    result
  end

  @spec execute_with_artifacts(Request.t(), reference(), integer()) ::
          {:ok, ProcResult.t()} | {:error, term()}
  defp execute_with_artifacts(request, owner_monitor, started_at) do
    with {:ok, artifacts} <- prepare_artifacts(request) do
      result =
        with {:ok, port} <- open_port(request, artifacts),
             :ok <- send_environment(port, Map.merge(request.env, Sandbox.child_env())) do
          collect(request, artifacts, port, owner_monitor, started_at)
        end

      cleanup_result(result, artifacts)
    end
  end

  @spec open_port(Request.t(), Artifacts.t()) :: {:ok, port()} | {:error, term()}
  defp open_port(request, artifacts) do
    if File.regular?(Wrapper.executable()) do
      do_open_port(request, artifacts)
    else
      {:error, :enoent}
    end
  end

  @spec do_open_port(Request.t(), Artifacts.t()) :: {:ok, port()} | {:error, term()}
  defp do_open_port(request, artifacts) do
    with {:ok, command} <- Sandbox.command(request.argv, request.sandbox) do
      args =
        Wrapper.arguments(
          artifacts.log_path,
          artifacts.stdin_path,
          request.timeout_ms,
          artifacts.remove_log,
          artifacts.remove_stdin,
          command
        )

      port =
        Port.open({:spawn_executable, Wrapper.executable()}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          :stderr_to_stdout,
          {:args, args},
          {:cd, request.cd}
        ])

      {:ok, port}
    end
  rescue
    ArgumentError -> {:error, :spawn_failed}
  end

  @spec send_environment(port(), map()) :: :ok | {:error, :runner_failed}
  defp send_environment(port, env) do
    if Port.command(port, Wrapper.environment_frame(env)), do: :ok, else: {:error, :runner_failed}
  end

  @spec collect(Request.t(), Artifacts.t(), port(), reference(), integer()) ::
          {:ok, ProcResult.t()} | {:error, term()}
  defp collect(request, artifacts, port, owner_monitor, started_at) do
    deadline = started_at + request.timeout_ms

    case receive_port(port, owner_monitor, deadline, <<>>) do
      {:ok, %WireResult{} = wire_result} ->
        finish(request, artifacts, wire_result, started_at)

      {:error, :caller_down} ->
        {:error, :caller_down}

      error ->
        error
    end
  end

  @spec receive_port(port(), reference(), integer(), binary()) ::
          {:ok, WireResult.t()} | {:error, term()}
  defp receive_port(port, owner_monitor, deadline, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        receive_port(port, owner_monitor, deadline, append_protocol(output, data))

      {^port, {:exit_status, _status}} ->
        parse_result(output)

      {:DOWN, ^owner_monitor, :process, _caller, _reason} ->
        cancel_and_reap(port, output)

      _message ->
        receive_port(port, owner_monitor, deadline, output)
    after
      remaining ->
        _ = Port.command(port, "TIMEOUT\n")
        reap_after_timeout(port, output)
    end
  end

  @spec cancel_and_reap(port(), binary()) :: {:error, :caller_down}
  defp cancel_and_reap(port, output) do
    _ = Port.command(port, "CANCEL\n")
    _ = await_exit(port, output)
    {:error, :caller_down}
  end

  @spec reap_after_timeout(port(), binary()) :: {:ok, WireResult.t()} | {:error, term()}
  defp reap_after_timeout(port, output) do
    case await_exit(port, output) do
      {:ok, %WireResult{} = result} -> {:ok, %{result | timed_out: true, exit_status: nil}}
      error -> error
    end
  end

  @spec await_exit(port(), binary()) :: {:ok, WireResult.t()} | {:error, term()}
  defp await_exit(port, output) do
    receive do
      {^port, {:data, data}} -> await_exit(port, append_protocol(output, data))
      {^port, {:exit_status, _status}} -> parse_result(output)
    after
      @cleanup_wait_ms ->
        _ = Port.close(port)
        {:error, :cleanup_failed}
    end
  end

  @spec append_protocol(binary(), binary()) :: binary()
  defp append_protocol(output, data) do
    size = 4_096 - byte_size(output)
    if size > 0, do: output <> binary_part(data, 0, min(byte_size(data), size)), else: output
  end

  @spec parse_result(binary()) :: {:ok, WireResult.t()} | {:error, atom()}
  defp parse_result(output) do
    case Regex.run(~r/DONE\|(-|\d+)\|([01])\|(\d+)/, output) do
      [_, status, timed_out, exec_error] -> wire_result(status, timed_out, exec_error)
      _ -> {:error, :runner_failed}
    end
  end

  @spec wire_result(String.t(), String.t(), String.t()) ::
          {:ok, WireResult.t()} | {:error, atom()}
  defp wire_result(status, timed_out, exec_error) do
    with {error_number, ""} <- Integer.parse(exec_error),
         {:ok, exit_status} <- parse_status(status, timed_out, error_number) do
      {:ok,
       %WireResult{
         exit_status: exit_status,
         timed_out: timed_out == "1",
         exec_error: error_number
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :runner_failed}
    end
  end

  @spec parse_status(String.t(), String.t(), non_neg_integer()) ::
          {:ok, integer() | nil} | {:error, atom()}
  defp parse_status(_status, "1", _error), do: {:ok, nil}
  defp parse_status(_status, _timed_out, 2), do: {:error, :enoent}
  defp parse_status(_status, _timed_out, error) when error > 0, do: {:error, :os_error}
  defp parse_status("-", _timed_out, 0), do: {:error, :runner_failed}

  defp parse_status(status, _timed_out, 0) do
    case Integer.parse(status) do
      {exit_status, ""} -> {:ok, exit_status}
      _ -> {:error, :runner_failed}
    end
  end

  @spec finish(Request.t(), Artifacts.t(), WireResult.t(), integer()) ::
          {:ok, ProcResult.t()} | {:error, term()}
  defp finish(request, artifacts, result, started_at) do
    with {:ok, tail} <- read_tail(artifacts.log_path) do
      {:ok,
       %ProcResult{
         argv: request.argv,
         exit_status: result.exit_status,
         timed_out: result.timed_out,
         output_tail: tail,
         log_path: request.log_path,
         duration_ms: max(System.monotonic_time(:millisecond) - started_at, 0)
       }}
    end
  end

  @spec read_tail(Path.t()) :: {:ok, binary()} | {:error, term()}
  defp read_tail(path) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary]) do
      result =
        with {:ok, size} <- :file.position(file, :eof),
             {:ok, _position} <- :file.position(file, max(size - @tail_bytes, 0)) do
          case :file.read(file, @tail_bytes) do
            {:ok, tail} -> {:ok, tail}
            :eof -> {:ok, <<>>}
            {:error, reason} -> {:error, reason}
          end
        end

      case {:file.close(file), result} do
        {:ok, {:ok, tail}} -> {:ok, tail}
        {:ok, {:error, reason}} -> {:error, reason}
        {_error, _result} -> {:error, :log_close_failed}
      end
    end
  end

  @spec prepare_artifacts(Request.t()) :: {:ok, Artifacts.t()} | {:error, term()}
  defp prepare_artifacts(request) do
    log_path = request.log_path || temporary_path(request.cd, "log")
    remove_log = is_nil(request.log_path)

    with :ok <- prepare_log(log_path, remove_log),
         {:ok, stdin_path, remove_stdin} <- prepare_stdin(request.stdin, request.cd) do
      {:ok,
       %Artifacts{
         log_path: log_path,
         stdin_path: stdin_path,
         remove_log: remove_log,
         remove_stdin: remove_stdin
       }}
    else
      {:error, reason} ->
        case if(remove_log, do: remove_quietly(log_path), else: :ok) do
          :ok -> {:error, reason}
          {:error, _cleanup_reason} -> {:error, :cleanup_failed}
        end
    end
  end

  @spec prepare_log(Path.t(), boolean()) :: :ok | {:error, term()}
  defp prepare_log(path, exclusive) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      options = if exclusive, do: [:write, :binary, :exclusive], else: [:write, :binary]

      with {:ok, file} <- File.open(path, options) do
        File.close(file)
      end
    end
  end

  @spec prepare_stdin(Request.stdin(), Path.t()) :: {:ok, Path.t(), boolean()} | {:error, term()}
  defp prepare_stdin(:null, _cd), do: {:ok, "/dev/null", false}
  defp prepare_stdin({:file, path}, _cd), do: {:ok, path, false}

  defp prepare_stdin({:binary, data}, cd) do
    path = temporary_path(cd, "stdin")

    case write_private_file(path, data) do
      :ok -> {:ok, path, true}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec temporary_path(Path.t(), String.t()) :: Path.t()
  defp temporary_path(cd, label) do
    name =
      ".kogen-proc-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}-#{label}"

    Path.join(cd, name)
  end

  @spec write_private_file(Path.t(), binary()) :: :ok | {:error, term()}
  defp write_private_file(path, data) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        chmod = :file.change_mode(String.to_charlist(path), 0o600)
        write = if chmod == :ok, do: IO.binwrite(file, data), else: chmod
        close = File.close(file)

        if chmod == :ok and write == :ok and close == :ok do
          :ok
        else
          reason = first_error([chmod, write, close])
          _ = remove_quietly(path)
          {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec cleanup_result({:ok, ProcResult.t()} | {:error, term()}, Artifacts.t()) ::
          {:ok, ProcResult.t()} | {:error, term()}
  defp cleanup_result(result, artifacts) do
    cleanup = cleanup_artifacts(artifacts)

    case {result, cleanup} do
      {{:ok, proc_result}, :ok} -> {:ok, proc_result}
      {{:error, reason}, :ok} -> {:error, reason}
      {_result, {:error, _reason}} -> {:error, :cleanup_failed}
    end
  end

  @spec first_error([term()]) :: term()
  defp first_error([{:error, reason} | _results]), do: reason
  defp first_error([:ok | results]), do: first_error(results)
  defp first_error([]), do: :file_error

  @spec cleanup_artifacts(Artifacts.t()) :: :ok | {:error, term()}
  defp cleanup_artifacts(artifacts) do
    paths =
      Enum.reject(
        [
          if(artifacts.remove_stdin, do: artifacts.stdin_path),
          if(artifacts.remove_log, do: artifacts.log_path)
        ],
        &is_nil/1
      )

    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case remove_quietly(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec remove_quietly(Path.t()) :: :ok | {:error, term()}
  defp remove_quietly(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
