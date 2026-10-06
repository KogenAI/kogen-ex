defmodule Kogen.Agents.ObservationTest do
  use Kogen.Testkit.Case

  import ExUnit.CaptureLog

  alias Kogen.Agents

  test "concurrent roles retain separate identities, activity and completed outcomes", %{
    tmp_dir: root
  } do
    first = start(root, "one", :planner, self())
    second = start(root, "two", :auditor, self())
    assert_receive {:started, "one", worker1}, 5_000
    assert_receive {:started, "two", worker2}, 5_000
    records = Agents.list([Path.join(root, "*")])
    assert Enum.sort(Enum.map(records, & &1.role)) == ["auditor", "planner"]
    assert Enum.sort(Enum.map(records, & &1.build)) == ["one", "two"]
    assert length(Enum.uniq_by(records, & &1.id)) == 2
    send(worker1, :finish)
    send(worker2, :finish)
    assert Task.await(first) == :done
    assert Task.await(second) == :done

    assert Enum.all?(
             Agents.list([Path.join(root, "*")]),
             &(&1.status == "finished" and &1.elapsed_ms >= 0)
           )

    assert Enum.all?(
             Agents.list([Path.join(root, "*")]),
             &(File.read!(&1.events_path) =~ "waiting")
           )
  end

  test "expired heartbeats are stale without addressing a saved process", %{tmp_dir: root} do
    id = String.duplicate("a", 32)
    dir = Path.join([root, "old", "agents", id])
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "agent.json"),
      :json.encode(%{
        id: id,
        status: "running",
        project: "old",
        build: "old",
        role: "builder",
        activity: "provider wait",
        started_at: 1,
        updated_at: 1,
        finished_at: :null,
        owner_os_pid: System.pid()
      })
    )

    assert [%{status: "stale", elapsed_ms: elapsed}] = Agents.list([Path.join(root, "*")])
    assert elapsed > 5_000
  end

  test "incomplete records do not break observation", %{tmp_dir: root} do
    dir = Path.join([root, "run", "agents", String.duplicate("a", 32)])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "agent.json"), "{}")

    assert capture_log(fn ->
             assert [] = Agents.list([Path.join(root, "*")])
           end) =~ "invalid_agent_record"
  end

  test "nested agents retain their parent identity", %{tmp_dir: root} do
    context = context(root, "nested")

    assert :done =
             Agents.run(context, :planner, fn ->
               Agents.run(context, :auditor, fn -> :done end)
             end)

    records = Agents.list([Path.join(root, "*")])
    parent = Enum.find(records, &(&1.role == "planner"))
    child = Enum.find(records, &(&1.role == "auditor"))
    assert child.parent_id == parent.id
    assert child.id != parent.id
  end

  test "an isolated worker stops when its owner disappears", %{tmp_dir: root} do
    owner = start(root, "orphan", :builder, self())
    assert_receive {:started, "orphan", worker}, 5_000
    Process.unlink(owner.pid)
    monitor = Process.monitor(worker)
    Process.exit(owner.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :shutdown}, 5_000
  end

  defp start(root, build, role, owner) do
    Task.async(fn ->
      Agents.run(context(root, build), role, fn ->
        Agents.activity("provider wait", :waiting)
        send(owner, {:started, build, self()})

        receive do
          :finish -> :done
        end
      end)
    end)
  end

  defp context(root, build),
    do: %{run_dir: Path.join(root, build), project: %{root: Path.join(root, "project-" <> build)}}
end
