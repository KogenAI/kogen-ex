defmodule Kogen.Contracts.WorkerGuard do
  @moduledoc "Stops an isolated worker when its owner disappears, without OS process signals."

  @spec watch(pid(), pid()) :: pid()
  def watch(owner, worker) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      worker_ref = Process.monitor(worker)

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _reason} -> stop(worker, worker_ref)
        {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
      end
    end)
  end

  defp stop(worker, monitor) do
    Process.exit(worker, :shutdown)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      1_000 -> Process.exit(worker, :kill)
    end
  end
end
