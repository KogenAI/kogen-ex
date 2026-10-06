defmodule Kogen.E2e.RequestJournalTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider

  @moduletag :e2e
  @moduletag timeout: 300_000

  setup_all do
    seed_project = Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)
    {:ok, seed_project: seed_project}
  end

  test "a Build stopped by a failing request keeps its journal and the usage already spent",
       context do
    parent = Path.join(context.tmp_dir, "stopped")
    File.mkdir_p!(parent)

    source = "defmodule TinyApp do\n  def value, do: :ready\nend\n"

    script = [
      :context |> ScriptedProvider.answer("Target TinyApp.value/0.") |> usage(100, 10),
      :plan |> ScriptedProvider.answer("Update TinyApp.value/0.") |> usage(200, 20),
      :develop |> ScriptedProvider.write("lib/tiny_app.ex", source) |> usage(300, 30),
      ScriptedProvider.fail(:develop, :login)
    ]

    result = Build.run!(parent, script, %Options{seed_project: context.seed_project})

    assert %Result{build: %{status: :failed}, run_status: :failed} = result
    assert_agents(result)
    records = requests(result)

    assert Enum.map(records, &{&1["stage"], &1["outcome"], &1["retries"]}) == [
             {"context", "ok", 0},
             {"plan", "ok", 0},
             {"develop", "ok", 0},
             {"develop", "login", 0}
           ]

    assert Enum.all?(records, &(&1["attempt"] == "builder" and &1["rung"] == :null))
    assert Enum.at(records, 2)["tool_output_bytes"] == 0
    assert [%{"history_items" => 3, "tool_output_bytes" => bytes}] = Enum.take(records, -1)
    assert bytes > 0

    report = result |> Build.report() |> elem(1) |> :json.decode()

    stages =
      Enum.map(report["model_stages"], &{&1["stage"], &1["partial"], &1["tokens"]["input"]})

    assert {"develop", true, 300} in stages
    assert {"plan", false, 200} in stages

    assert %{"attempt" => "builder", "tokens" => %{"input" => 600, "output" => 60}} =
             attempt(report)

    run = result.fixture.workspace_root |> Kogen.State.load(result.build.run_id) |> elem(1)

    assert {:ok, %{tokens: %{"input" => 600, "output" => 60}}} =
             Kogen.State.attempt_usage(run, "builder")
  end

  defp assert_agents(result) do
    records =
      result.build.run_dir
      |> Path.join("**/agents/*/agent.json")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> File.read!() |> :json.decode()))

    assert Enum.sort(Enum.map(records, & &1["role"])) == ["builder", "context", "planner"]
    assert Enum.all?(records, &(&1["project"] == result.fixture.project_root))
    assert Enum.all?(records, &(&1["build"] == result.build.run_id))
    assert Enum.all?(records, &(&1["status"] == "finished"))
  end

  defp usage(step, input, output),
    do: ScriptedProvider.with_usage(step, %{input: input, output: output})

  defp attempt(report), do: Enum.find(report["attempts"], &(&1["attempt"] == "builder"))

  defp requests(%Result{build: %{run_dir: run_dir}}) do
    run_dir
    |> Path.join("requests.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&:json.decode/1)
    |> Enum.filter(&(&1["record_kind"] == "model_request" and is_integer(&1["started_at"])))
  end
end
