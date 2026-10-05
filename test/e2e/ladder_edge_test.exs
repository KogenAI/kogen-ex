defmodule Kogen.E2e.LadderEdgeTest do
  use Kogen.Testkit.Case

  import Kogen.E2e.Ladder, only: [done: 0, events: 2, shell: 1, source_at: 2, user_text: 1]

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.Ladder
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Temp

  @moduletag :e2e
  @moduletag timeout: 300_000

  @plan "Difficulty: normal\n## Acceptance criteria\n1. TinyApp.value/0 returns :ready."
  @hard_plan "Difficulty: hard\n## Acceptance criteria\n1. TinyApp.value/0 returns :ready."

  setup_all do
    root = Temp.create!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, seed: Ladder.seed!(root)}
  end

  test "a lone green Candidate failing edge tests gets one repair round; the better one lands",
       context do
    script = [
      ScriptedProvider.answer(:plan, @plan),
      write("builder", ""),
      done(),
      edge_reply([value_test(), label_test(), wrong_test()]),
      write("builder-edge", "  def label, do: \"ready\"\n"),
      done()
    ]

    result = Ladder.run!(context.tmp_dir, "repair", script, context.seed, "ladder+edge")

    assert %Result{build: %{status: :landed, landed_sha: sha}} = result
    assert source_at(result, sha) =~ "# revision: builder-edge"

    # One Sol high edge call from the Request alone.
    assert [edge_call] =
             Enum.filter(result.provider_requests, &(&1.instructions =~ "edge-test writer"))

    assert {edge_call.model, edge_call.effort} == {"gpt-6.1-sol", "high"}
    text = user_text(edge_call)
    assert text =~ "Preserve this fixture wording verbatim as source context."
    assert text =~ "TinyApp"
    refute text =~ "TinyApp.value/0 returns :ready"
    refute text =~ "Acceptance criteria"

    # The repair continues the green builder session with only the edge findings.
    repair = result.provider_requests |> Enum.filter(&(&1.tools != [])) |> Enum.at(2)
    assert inspect(repair.input) =~ "these edge tests failed"
    assert inspect(repair.input) =~ "labels the ready value"
    refute inspect(repair.input) =~ "def label"

    assert {:ok, report} = Build.report(result)
    edge = :json.decode(report)["edge_probe"]

    assert %{"status" => "complete", "generated" => 3, "kept" => 2} = edge
    assert edge["selected"] == "builder-edge"
    assert %{"attempt" => "builder-edge", "result" => "green"} = edge["repair"]

    assert passes(edge) == [
             {"builder", 1, 1, ["labels the ready value", "is never idle"]},
             {"builder-edge", 2, 2, ["is never idle"]}
           ]

    assert Enum.map(events(result, "rung_finished"), &{&1.attempt, &1.result, &1.reason}) == [
             {"builder-edge", "green", "green"},
             {"builder", "green", "not_selected"}
           ]
  end

  test "edge tests never block landing: an unhelpful repair leaves the original to land",
       context do
    script = [
      ScriptedProvider.answer(:plan, @plan),
      write("builder", ""),
      done(),
      edge_reply([value_test(), label_test()]),
      write("builder-edge", ""),
      done()
    ]

    result =
      Ladder.run!(context.tmp_dir, "unhelpful", script, context.seed, "ladder", %{
        edge_tests: true
      })

    assert %Result{build: %{status: :landed, landed_sha: sha}} = result
    assert source_at(result, sha) =~ "# revision: builder\n"

    assert {:ok, report} = Build.report(result)
    edge = :json.decode(report)["edge_probe"]
    assert %{"generated" => 2, "kept" => 1, "selected" => "builder"} = edge
    assert [{"builder", 1, 1, _failed}, {"builder-edge", 1, 1, _same}] = passes(edge)
    assert [%{attempt: "builder-edge", reason: "not_selected"}] = events(result, "candidate_diff")
  end

  test "an unusable edge reply is recorded and the green Candidate lands", context do
    script = [
      ScriptedProvider.answer(:plan, @plan),
      write("builder", ""),
      done(),
      ScriptedProvider.answer(:edge, "I would rather not write tests.")
    ]

    result = Ladder.run!(context.tmp_dir, "unusable", script, context.seed, "ladder+edge")

    assert %Result{build: %{status: :landed}} = result
    assert {:ok, report} = Build.report(result)

    assert %{"status" => "unavailable", "reason" => "no_test_module", "generated" => 0} =
             :json.decode(report)["edge_probe"]
  end

  test "parallel green Candidates rank by kept edge tests passed before the smaller diff",
       context do
    builder = [write("builder", "  def label, do: \"ready\"\n"), done()]
    sol = [write("sol-medium", ""), done()]

    script =
      [ScriptedProvider.answer(:plan, @hard_plan)] ++
        ScriptedProvider.for_model(builder, "gpt-6-luna") ++
        ScriptedProvider.for_model(sol, "gpt-6.1-sol", "medium") ++
        [edge_reply([value_test(), label_test()])]

    result = Ladder.run!(context.tmp_dir, "parallel", script, context.seed, "ladder+edge")

    assert %Result{build: %{status: :landed, landed_sha: sha}} = result
    assert source_at(result, sha) =~ "# revision: builder"
    assert [%{attempt: "builder", result: "green"}] = events(result, "parallel_selected")

    assert {:ok, report} = Build.report(result)
    edge = :json.decode(report)["edge_probe"]
    assert %{"generated" => 2, "kept" => 2, "repair" => :null} = edge

    assert passes(edge) == [
             {"builder", 2, 2, []},
             {"sol-medium", 1, 1, ["labels the ready value"]}
           ]
  end

  defp passes(edge) do
    edge["candidates"]
    |> Enum.map(&{&1["candidate"], &1["passed"], &1["kept_passed"], &1["failed"]})
    |> Enum.sort()
  end

  defp write(revision, extra) do
    source =
      "defmodule TinyApp do\n  # revision: #{revision}\n  def value, do: :ready\n#{extra}end\n"

    shell("cat > lib/tiny_app.ex <<'EOF'\n#{source}EOF")
  end

  defp edge_reply(tests) do
    ScriptedProvider.answer(:edge, """
    ```elixir
    defmodule KogenEdge.TinyAppTest do
      use ExUnit.Case, async: true

    #{Enum.join(tests, "\n")}
    end
    ```
    """)
  end

  defp value_test do
    """
      test "returns the ready value twice" do
        assert TinyApp.value() == TinyApp.value()
      end
    """
  end

  defp label_test do
    """
      test "labels the ready value" do
        assert apply(TinyApp, :label, []) == "ready"
      end
    """
  end

  # Wrong for every Candidate, so it is discarded.
  defp wrong_test do
    """
      test "is never idle" do
        assert TinyApp.value() == :idle
      end
    """
  end
end
