defmodule Kogen.E2e.LadderTest do
  use Kogen.Testkit.Case

  import Kogen.E2e.Ladder,
    only: [done: 0, events: 2, source_at: 2, stage_events: 2, user_text: 1, write: 2, write: 3]

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.Ladder
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Temp

  @moduletag :e2e
  @moduletag timeout: 300_000

  @plan "Difficulty: normal\n## Acceptance criteria\n1. TinyApp.value/0 returns :ready."
  @hard_plan "Difficulty: hard\n## Acceptance criteria\n1. TinyApp.value/0 returns :ready."
  @upheld ~s({"items":[{"id":"A1","verdict":"valid","reason":"The Request asks for :ready."}]})

  setup_all do
    root = Temp.create!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, seed: Build.prepare_seed!(root, project_config: Ladder.tests_project())}
  end

  test "stopped rungs move up the ladder on fresh Candidates until one is green", context do
    script = [
      ScriptedProvider.answer(:plan, @plan),
      write("builder", :wrong),
      done(),
      ScriptedProvider.answer(:audit, @upheld),
      done(),
      write("sol-medium", :wrong),
      done(),
      done(),
      write("sol-high", :ready),
      done()
    ]

    result = run!(context, "climb", script)

    assert %Result{build: %{status: :landed, landed_sha: sha}} = result
    assert source_at(result, sha) =~ "# revision: sol-high"

    assert develop_settings(result) == [
             {"gpt-6-luna", "max"},
             {"gpt-6-luna", "max"},
             {"gpt-6-luna", "max"},
             {"gpt-6.1-sol", "medium"},
             {"gpt-6.1-sol", "medium"},
             {"gpt-6.1-sol", "medium"},
             {"gpt-6.1-sol", "high"},
             {"gpt-6.1-sol", "high"}
           ]

    assert [first, second] = events(result, "escalation_started")
    assert {first.attempt, first.trigger} == {"sol-medium", "unchanged"}
    assert {second.attempt, second.trigger} == {"sol-high", "unchanged"}

    sol_high = Enum.find(result.provider_requests, &(&1.effort == "high" and &1.tools != []))
    text = user_text(sol_high)
    assert text =~ "<plan>\n#{@plan}\n</plan>"
    assert text =~ "The builder attempt stopped after unchanged."
    assert text =~ "The sol-medium attempt stopped after unchanged."
    refute text =~ "# revision: builder"
    refute text =~ "# revision: sol-medium"

    repair = result.provider_requests |> Enum.filter(&(&1.model == "gpt-6-luna")) |> Enum.at(2)
    assert inspect(repair.input) =~ "upheld them; change the implementation, not the tests: A1"

    assert [%{item: "A1", verdict: "valid"}] = events(result, "acceptance_upheld")
    assert events(result, "acceptance_demoted") == []

    rungs = events(result, "rung_finished")

    assert Enum.map(rungs, &{&1.attempt, &1.result}) == [
             {"builder", "failed"},
             {"sol-medium", "failed"},
             {"sol-high", "green"}
           ]

    assert Enum.all?(rungs, &(is_integer(&1.wall_ms) and is_map(&1.tokens)))
    assert {:ok, report} = Build.report(result)
    assert %{"rungs" => [_, _, _], "best_candidate" => :null} = :json.decode(report)
  end

  test "a hard plan runs the first two rungs in parallel and lands the better one", context do
    luna = [write("builder", :wrong), done(), done()]
    sol = [write("sol-medium", :ready), done()]

    script =
      [ScriptedProvider.answer(:plan, @hard_plan)] ++
        ScriptedProvider.for_model(luna, "gpt-6-luna") ++
        ScriptedProvider.for_model(sol, "gpt-6.1-sol", "medium") ++
        [
          ScriptedProvider.for_model(
            ScriptedProvider.answer(:audit, @upheld),
            "gpt-6.1-sol",
            "high"
          )
        ]

    result = run!(context, "parallel", script)

    assert %Result{build: %{status: :landed, landed_sha: sha}} = result
    assert source_at(result, sha) =~ "# revision: sol-medium"

    assert [%{attempts: ["builder", "sol-medium"]}] = events(result, "parallel_started")
    assert [selected] = events(result, "parallel_selected")
    assert {selected.attempt, selected.result} == {"sol-medium", "green"}
    assert events(result, "escalation_started") == []

    assert Enum.sort(Enum.map(events(result, "rung_finished"), &{&1.attempt, &1.result})) == [
             {"builder", "failed"},
             {"sol-medium", "green"}
           ]

    assert [%{attempt: "builder", reason: "not_selected"}] = events(result, "candidate_diff")
  end

  test "with no green rung the best Candidate is pushed to kogen/<slug>", context do
    script = [
      ScriptedProvider.answer(:plan, @plan),
      write("builder", :wrong, ~w(padding-one padding-two padding-three)),
      done(),
      ScriptedProvider.answer(:audit, @upheld),
      done(),
      done(),
      done(),
      write("sol-high", :wrong),
      done(),
      done(),
      write("raw-request", :wrong, ~w(padding-one padding-two)),
      done(),
      done()
    ]

    result =
      Ladder.run!(context.tmp_dir, "best", script, context.seed, "ladder", %{repeat_from: nil})

    assert %Result{build: %{status: :failed}} = result
    assert "build: needs attention: kogen/build-engine" in result.build.lines

    raw =
      result.provider_requests
      |> Enum.filter(&(&1.effort == "high" and &1.tools != []))
      |> Enum.at(3)

    text = user_text(raw)
    assert text =~ "## Request\nPreserve this fixture wording verbatim as source context."
    assert text =~ "## Acceptance tests"
    assert text =~ "returns the ready value"
    refute text =~ "<plan>"
    refute text =~ "Make TinyApp.value/0 return the approved ready value."

    assert [best] = events(result, "best_candidate")
    assert {best.attempt, best.branch} == {"sol-high", "kogen/build-engine"}
    assert best.metrics["checks_green"] == true
    assert best.failing["acceptance"] != []

    branch = Git.git!(result.fixture.origin, ["rev-parse", "refs/heads/kogen/build-engine"])
    assert String.trim(branch) == best.commit
    assert source_at(result, best.commit) =~ "# revision: sol-high"

    files = Enum.map(events(result, "candidate_diff"), & &1.attempt)
    assert files == ["builder", "sol-high", "raw-request"]

    assert {:ok, report} = Build.report(result)
    decoded = :json.decode(report)

    assert %{"best_candidate" => %{"branch" => "kogen/build-engine", "attempt" => "sol-high"}} =
             decoded

    assert length(decoded["rungs"]) == 4

    assert {:ok, statuses} =
             Kogen.Kernel.status(result.fixture.project_root, result.fixture.origin, "main")

    assert [%{status: :failed, detail: "needs attention: kogen/build-engine"}] = statuses
  end

  test "ladder-luna climbs fresh Luna max rungs with a Luna auditor and no Sol", context do
    script = [
      ScriptedProvider.answer(:plan, @plan),
      write("builder", :wrong),
      done(),
      ScriptedProvider.answer(:audit, @upheld),
      done(),
      write("fresh-2", :ready),
      done()
    ]

    result = run!(context, "luna", script, "ladder-luna")

    assert %Result{build: %{status: :landed, landed_sha: sha}} = result
    assert source_at(result, sha) =~ "# revision: fresh-2"

    assert Enum.uniq(Enum.map(result.provider_requests, &{&1.model, &1.effort})) == [
             {"gpt-6-luna", "max"}
           ]

    assert [%{attempt: "fresh-2", trigger: "unchanged"}] = events(result, "escalation_started")
    assert [%{model: "gpt-6-luna", effort: "max"}] = stage_events(result, "audit")
    assert [%{recipe: "ladder-luna"}] = events(result, "started")
  end

  test "ladder-sol-medium keeps planning and building on Sol medium", context do
    script = [ScriptedProvider.answer(:plan, @plan), write("sol-medium", :ready), done()]

    result = run!(context, "sol-medium-only", script, "ladder-sol-medium")

    assert %Result{build: %{status: :landed}} = result

    assert Enum.uniq(Enum.map(result.provider_requests, &{&1.model, &1.effort})) == [
             {"gpt-6.1-sol", "medium"}
           ]

    assert [%{recipe: "ladder-sol-medium"}] = events(result, "started")
  end

  defp run!(context, name, script, recipe \\ "ladder"),
    do: Ladder.run!(context.tmp_dir, name, script, context.seed, recipe)

  defp develop_settings(result) do
    for request <- result.provider_requests,
        request.tools != [],
        do: {request.model, request.effort}
  end
end
