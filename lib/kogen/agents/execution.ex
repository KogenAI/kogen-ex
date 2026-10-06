defmodule Kogen.Agents.Execution do
  @moduledoc false

  alias Kogen.Agents.Codec
  alias Kogen.Agents.Store

  def run(run_dir, project, role, operation) do
    record = initial(run_dir, project, role)

    with {:ok, dir} <- Store.create(run_dir, record) do
      caller = self()
      {worker, monitor} = spawn_monitor(fn -> execute(caller, dir, record.id, operation) end)
      await(dir, record, worker, monitor)
    end
  end

  defp initial(run_dir, project, role) do
    now = System.system_time(:millisecond)

    %{
      id: Store.id(),
      parent_id: Process.get(:kogen_agent),
      project: project,
      build: Codec.build(run_dir),
      role: Atom.to_string(role),
      activity: "starting",
      status: "running",
      started_at: now,
      updated_at: now,
      finished_at: nil,
      outcome: nil
    }
  end

  defp execute(caller, dir, id, operation) do
    Kogen.Contracts.WorkerGuard.watch(caller, self())
    Process.put(:kogen_agent, id)
    Process.put(:kogen_agent_owner, {caller, dir})
    send(caller, {:agent_result, self(), operation.()})
  end

  def activity(detail, status) do
    case Process.get(:kogen_agent_owner) do
      {owner, _dir} -> send(owner, {:agent_activity, self(), detail, status})
      nil -> :ok
    end

    :ok
  end

  defp await(dir, record, worker, monitor) do
    receive do
      {:agent_result, ^worker, result} ->
        Process.demonitor(monitor, [:flush])
        finish(dir, record, "finished", result)

      {:agent_activity, ^worker, detail, status} ->
        :ok =
          Store.event(dir, %{event: "activity", id: record.id, activity: detail, status: status})

        await(
          dir,
          %{record | activity: detail, status: Atom.to_string(status)},
          worker,
          monitor
        )

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        finish(dir, record, "failed", {:error, :agent_failed})
    after
      50 -> poll(dir, record, worker, monitor)
    end
  end

  defp poll(dir, record, worker, monitor) do
    record = %{record | updated_at: System.system_time(:millisecond)}
    :ok = Store.write(dir, record)
    await(dir, record, worker, monitor)
  end

  defp finish(dir, record, outcome, result) do
    now = System.system_time(:millisecond)

    final = %{
      record
      | status: "finished",
        activity: outcome,
        outcome: outcome,
        updated_at: now,
        finished_at: now
    }

    :ok = Store.write(dir, final)
    :ok = Store.event(dir, final)
    result
  end
end
