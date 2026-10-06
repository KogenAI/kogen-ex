defmodule Kogen.Kernel.AgentStatusTest do
  use Kogen.Testkit.Case

  import ExUnit.CaptureIO

  alias Kogen.Agents
  alias Kogen.Kernel.CLI
  alias Kogen.State.Json
  alias Kogen.State.Run
  alias Kogen.Testkit.Git

  @fixture Path.expand("../../fixtures/hello_app/.kogen/project.yaml", __DIR__)

  test "project status retains Intent JSON and reports only this project's agents", %{
    tmp_dir: root
  } do
    project = project!(root)
    run = run!(project)
    context = %{run_dir: run.dir, project: %{root: project}}
    assert :done = Agents.run(context, :planner, fn -> :done end)
    assert :done = Agents.run(%{context | project: %{root: root}}, :auditor, fn -> :done end)

    assert {0, text} = status(project)
    assert text =~ "Agents:\n"
    assert text =~ "planner Build=#{run.id}"
    assert text =~ "finished elapsed_ms="
    assert text =~ "events:"
    refute text =~ "auditor"

    assert {0, json} = status(project, ["--json"])
    [intent, agent] = json |> String.split("\n", trim: true) |> Enum.map(&:json.decode/1)
    assert intent["slug"] == "greet"
    assert agent["type"] == "agent"
    assert agent["project"] == project
    assert agent["build"] == run.id
    assert agent["role"] == "planner"
    assert agent["parent_id"] == :null
    assert is_integer(agent["elapsed_ms"])
    assert File.exists?(agent["events_path"])

    assert {0, text} = status(project, ["greet"])
    assert text =~ "planner Build=#{run.id}"
    assert {0, json} = status(project, ["greet", "--json"])
    report = :json.decode(json)
    assert report["build_id"] == run.id
    assert [%{"id" => id}] = report["agents"]
    assert id == agent["id"]
  end

  test "watch follows an active shaper with no Build until completion", %{tmp_dir: root} do
    project = project!(root)

    shape_root =
      Path.join([Path.dirname(Path.dirname(root)), "kogen-shaper", Path.basename(root)])

    on_exit(fn -> File.rm_rf!(shape_root) end)
    task = start_agent(project, Path.join(shape_root, "shape-run"))
    assert_receive {:started, worker}, 5_000

    output =
      capture_io(fn ->
        watcher = Task.async(fn -> status(project, ["--watch"]) end)
        wait_for_snapshot(Process.group_leader())
        send(worker, :finish)
        assert Task.await(watcher, 30_000) == {0, ""}
      end)

    assert Task.await(task) == :done
    assert output =~ "shaper Build=shape-run running"
    assert output =~ "shaper Build=shape-run finished"
    assert {0, json} = status(project, ["--json"])
    [_intent, agent] = json |> String.split("\n", trim: true) |> Enum.map(&:json.decode/1)
    assert agent["role"] == "shaper"
    assert agent["outcome"] == "finished"
  end

  test "queue stop keeps its idle behavior while a shaping agent is active", %{tmp_dir: root} do
    project = project!(root)
    task = start_agent(project, Path.join([project, ".kogen", "shape-run"]))
    assert_receive {:started, worker}, 5_000
    assert CLI.execute(["queue", "stop", "--project", project]) == {0, "queue: not running\n"}
    assert Process.alive?(worker)
    send(worker, :finish)
    assert Task.await(task) == :done
  end

  defp status(project, arguments \\ []),
    do: CLI.execute(["status" | arguments] ++ ["--project", project])

  defp wait_for_snapshot(io, attempts \\ 250)
  defp wait_for_snapshot(_io, 0), do: flunk("watch never printed the active agent")

  defp wait_for_snapshot(io, attempts) do
    {_input, output} = StringIO.contents(io)

    if !(output =~ "shaper Build=shape-run running") do
      receive do
      after
        20 -> wait_for_snapshot(io, attempts - 1)
      end
    end
  end

  defp start_agent(project, run_dir) do
    owner = self()

    Task.async(fn ->
      Agents.run(%{run_dir: run_dir, project: %{root: project}}, :shaper, fn ->
        send(owner, {:started, self()})

        receive do
          :finish -> :done
        end
      end)
    end)
  end

  defp project!(root) do
    project = Git.create!(root)
    intent = Path.join([project, ".kogen", "intents", "greet", "intent.md"])
    File.mkdir_p!(Path.dirname(intent))
    File.write!(intent, "Draft Intent\n")
    File.cp!(@fixture, Path.join(project, ".kogen/project.yaml"))
    project
  end

  defp run!(project) do
    id = String.duplicate("a", 32)
    dir = Path.join([project, ".kogen", "runs", id])

    run = %Run{
      id: id,
      dir: dir,
      slug: "greet",
      intent_sha256: String.duplicate("b", 64),
      target_branch: "main",
      approval_commit: nil,
      status: :failed,
      landing: nil
    }

    {:ok, json} = Json.encode_run(run)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "run.json"), json)
    File.write!(Path.join(dir, "events.jsonl"), "")
    run
  end
end
