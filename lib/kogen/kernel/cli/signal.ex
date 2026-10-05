defmodule Kogen.Kernel.CLI.Signal do
  @moduledoc false
  @behaviour :gen_event

  alias Kogen.Cli.Args
  alias Kogen.Cli.Arguments

  @spec run([String.t()], ([String.t()] -> {non_neg_integer(), String.t()})) ::
          {non_neg_integer(), String.t()}
  def run(argv, executor) do
    owner = self()
    result_ref = make_ref()

    case install(owner) do
      :ok ->
        {worker, monitor} =
          spawn_monitor(fn -> send(owner, {result_ref, executor.(argv)}) end)

        await_result(argv, result_ref, worker, monitor)

      {:error, reason} ->
        {2, "kogen: cannot install SIGTERM handler: #{inspect(reason)}\n"}
    end
  end

  @impl :gen_event
  def init(owner), do: {:ok, owner}

  @impl :gen_event
  def handle_event(:sigterm, owner) do
    send(owner, {__MODULE__, :sigterm})
    {:ok, owner}
  end

  def handle_event(_event, owner), do: {:ok, owner}

  @impl :gen_event
  def handle_call(_request, owner), do: {:ok, :ok, owner}

  @impl :gen_event
  def handle_info(_info, owner), do: {:ok, owner}

  @impl :gen_event
  def terminate(_reason, _owner), do: :ok

  @impl :gen_event
  def code_change(_old_version, owner, _extra), do: {:ok, owner}

  defp await_result(argv, result_ref, worker, monitor) do
    receive do
      {^result_ref, {status, output}} ->
        Process.demonitor(monitor, [:flush])
        restore()
        {status, output}

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        restore()
        {1, "kogen: command failed: #{inspect(reason)}\n"}

      {__MODULE__, :sigterm} ->
        Process.exit(worker, :kill)
        await_worker_down(worker, monitor)
        record_interruption(argv)
        {143, ""}
    end
  end

  defp install(owner) do
    with :ok <- :os.set_signal(:sigterm, :handle),
         :ok <- :gen_event.add_handler(:erl_signal_server, __MODULE__, owner) do
      case :gen_event.delete_handler(:erl_signal_server, :erl_signal_handler, :normal) do
        :ok ->
          :ok

        reason ->
          restore()
          {:error, reason}
      end
    else
      {:error, reason} ->
        restore()
        {:error, reason}
    end
  end

  defp restore do
    _ = :gen_event.delete_handler(:erl_signal_server, __MODULE__, :normal)
    _ = :gen_event.add_handler(:erl_signal_server, :erl_signal_handler, [])
    _ = :os.set_signal(:sigterm, :default)
    :ok
  end

  defp await_worker_down(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp record_interruption(argv) do
    case Arguments.parse(argv) do
      {:ok, %Args{command: :build, positionals: [slug], project: project}} ->
        project = Path.expand(project || ".")
        _result = Kogen.Kernel.interrupt_build(project, slug)
        :ok

      _other ->
        :ok
    end
  end
end
