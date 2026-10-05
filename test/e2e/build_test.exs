defmodule Kogen.E2e.BuildTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @tag timeout: 120_000
  @intent_slug "build-engine"
  @intent_title "Expose a ready value"

  setup_all do
    seed_project = Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)
    {:ok, seed_project: seed_project}
  end

  test "all four Build scenarios pass concurrently", context do
    scenarios = [
      fn -> happy_path(context) end,
      fn -> review_revision(context) end,
      fn -> persistently_red_acceptance(context) end,
      fn -> moved_base(context) end
    ]

    results =
      scenarios
      |> Task.async_stream(fn scenario -> scenario.() end,
        max_concurrency: 4,
        timeout: 120_000
      )
      |> Enum.to_list()

    assert results == List.duplicate({:ok, :ok}, 4)
  end

  test "direct recipe lands without context, plan, or review calls", context do
    parent = scenario_parent(context, "direct-recipe")

    script = [
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", ready_source("direct", :ready)),
      ScriptedProvider.answer(:develop, "Done.")
    ]

    result =
      Build.run!(parent, script, %Options{seed_project: context.seed_project, recipe: "direct"})

    assert %Result{build: %{status: :landed}, run_status: :landed} = result
    assert result.provider_requests != []
    assert [started] = Enum.filter(result.events, &(&1.event == "started"))
    assert started.recipe == "direct"
    assert [develop] = Enum.filter(result.events, &(&1.event == "model_stage"))
    assert develop.stage == "develop"

    assert {:ok, report} = Build.report(result)
    assert %{"recipe" => "direct"} = :json.decode(report)
  end

  test "direct-shell lands with shell edits only", context do
    parent = scenario_parent(context, "direct-shell-recipe")

    shell_edit = "cat > lib/tiny_app.ex <<'EOF'\n" <> ready_source("shell", :ready) <> "EOF"

    script = [
      ScriptedProvider.call(:develop, "shell", %{"cmd" => shell_edit}),
      ScriptedProvider.answer(:develop, "Done.")
    ]

    result =
      Build.run!(parent, script, %Options{
        seed_project: context.seed_project,
        recipe: "direct-shell"
      })

    assert %Result{build: %{status: :landed, landed_sha: landed_sha}, run_status: :landed} =
             result

    assert [started] = Enum.filter(result.events, &(&1.event == "started"))
    assert started.recipe == "direct-shell"
    assert [develop] = Enum.filter(result.events, &(&1.event == "model_stage"))
    assert develop.stage == "develop"

    [request, _done_request] = result.provider_requests
    assert Enum.map(request.tools, & &1["name"]) == ["shell"]
    assert request.instructions =~ "sed -n"
    landed_source = Git.git!(result.fixture.origin, ["show", "#{landed_sha}:lib/tiny_app.ex"])
    assert landed_source =~ "def value, do: :ready"

    assert {:ok, report} = Build.report(result)
    assert %{"recipe" => "direct-shell"} = :json.decode(report)
  end

  defp happy_path(context) do
    parent = scenario_parent(context, "happy-path")
    result = Build.run!(parent, landing_script(), options(context.seed_project))
    assert %Result{build: %{status: :landed, landed_sha: sha}, run_status: :landed} = result
    assert result.claim_released

    assert result.build.run_dir ==
             Path.join([result.fixture.workspace_root, "runs", result.build.run_id])

    assert File.regular?(Path.join(result.build.run_dir, "run.json"))

    message = Git.git!(result.fixture.origin, ["show", "-s", "--format=%B", sha])

    assert String.trim_trailing(message, "\n") ==
             "#{@intent_title}\n\nKogen-Intent: #{@intent_slug}"

    parents = Git.git!(result.fixture.origin, ["rev-list", "--parents", "-n", "1", sha])
    assert String.split(String.trim(parents)) == [sha, result.fixture.approved_base]
    assert Enum.any?(result.events, &(&1.event == "finished" and &1.status == "landed"))
    assert Enum.count(result.events, &(&1.event == "check_result")) == 1
    assert Enum.count(result.events, &(&1.event == "acceptance_result")) == 1

    model_stages = Enum.filter(result.events, &(&1.event == "model_stage"))
    assert Enum.all?(model_stages, &is_integer(&1.wall_ms))
    assert_staged_roles_and_timing(result)
    :ok
  end

  defp assert_staged_roles_and_timing(result) do
    started = Enum.find(result.events, &(&1.event == "started"))

    assert started.roles == %{
             "context" => %{"model" => "gpt-6-luna", "effort" => "low"},
             "planner" => %{"model" => "gpt-6.1-sol", "effort" => "high"},
             "builder" => %{"model" => "scripted-model", "effort" => "medium"},
             "reviewer" => %{"model" => "gpt-6.1-sol", "effort" => "high"}
           }

    timings = Enum.filter(result.events, &(&1.event == "phase_timing"))
    assert Enum.any?(timings, &(&1.name == "fix-loop" and is_integer(&1.wall_ms)))
    assert Enum.any?(timings, &(&1.name == "commit" and is_integer(&1.wall_ms)))
    assert Enum.any?(timings, &(&1.name == "land" and is_integer(&1.wall_ms)))

    assert {:ok, report} = Build.report(result)
    decoded_report = :json.decode(report)
    assert decoded_report["roles"] == started.roles
    assert Enum.any?(decoded_report["phase_timings"], &(&1["name"] == "commit"))
  end

  defp review_revision(context) do
    parent = scenario_parent(context, "review-revision")
    script = landing_script("revise once")
    result = Build.run!(parent, script, options(context.seed_project))
    assert result.build.status == :landed
    assert result.run_status == :landed
    assert result.claim_released
    assert Enum.any?(result.events, &(&1.event == "repair" and &1.reason == "review_revise"))

    reviews = Enum.count(result.events, &(&1.event == "model_stage" and &1.stage == "review"))
    assert reviews == 2
    :ok
  end

  defp persistently_red_acceptance(context) do
    parent = scenario_parent(context, "red-acceptance")
    result = Build.run!(parent, red_acceptance_script(), options(context.seed_project))
    fixture = result.fixture

    assert result.build.status == :failed
    assert result.build.failure.class == :candidate
    assert result.run_status == :failed
    assert result.claim_released
    assert Enum.any?(result.events, &(&1.event == "finished" and &1.status == "failed"))
    approved_base = fixture.approved_base

    current_base = fixture.origin |> Git.git!(["rev-parse", "refs/heads/main"]) |> String.trim()
    assert current_base == approved_base

    assert Enum.any?(result.events, fn event ->
             event.event == "acceptance_result" and match?(%{"status" => "fail"}, event.result)
           end)

    :ok
  end

  defp moved_base(context) do
    parent = scenario_parent(context, "moved-base")
    options = %Options{seed_project: context.seed_project, move_base_on: :context}
    result = Build.run!(parent, landing_script(), options)
    fixture = result.fixture

    assert %Result{build: %{status: :landed, landed_sha: landed_sha}, run_status: :landed} =
             result

    assert result.claim_released

    moved_base = fixture.origin |> Git.git!(["rev-parse", "refs/heads/main"]) |> String.trim()
    assert moved_base == landed_sha

    commit_parent =
      fixture.origin |> Git.git!(["rev-parse", "#{landed_sha}^"]) |> String.trim()

    assert commit_parent != fixture.approved_base

    assert Git.git!(fixture.origin, ["log", "-1", "--format=%s", commit_parent]) =~
             "Advance base"

    :ok
  end

  test "scope warnings reach the reviewer and the final report", context do
    parent = scenario_parent(context, "scope-warning")

    script = [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", ready_source("candidate", :ready)),
      ScriptedProvider.write(:develop, "README.md", "Out-of-scope note.\n"),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, review_text("accept", :accept))
    ]

    result = Build.run!(parent, script, options(context.seed_project))

    assert %Result{build: %{status: :landed}} = result
    assert [warning] = Enum.filter(result.events, &(&1.event == "scope_warning"))
    assert warning.path == "README.md"
    assert warning.declared_domains == ["kernel"]

    reviewer =
      Enum.find(
        result.provider_requests,
        &String.contains?(&1.instructions, "advisory code reviewer")
      )

    assert reviewer
    assert inspect(reviewer.input) =~ warning.detail

    assert {:ok, report} = Build.report(result)

    assert %{"findings" => [%{"type" => "scope_warning", "path" => "README.md"}]} =
             :json.decode(report)
  end

  test "a same-seed test flake that fails on base is excused and reported", context do
    parent = scenario_parent(context, "flake-policy")
    marker = Path.join(parent, "candidate-test-ran")

    project_config = """
    name: tiny_app
    checks:
      - name: tests
        argv: [mix, test]
        timeout_ms: 60000
    fix: []
    env:
      KOGEN_FLAKE_MARKER: "#{marker}"
    domains:
      kernel: [lib]
    """

    seed_project =
      Build.prepare_seed!(parent,
        project_config: project_config,
        extra_files: %{"test/flaky_test.exs" => flaky_test_source()}
      )

    result = Build.run!(parent, flake_script(), %Options{seed_project: seed_project})

    assert %Result{build: %{status: :landed}} = result
    assert [flake] = Enum.filter(result.events, &(&1.event == "flake_excused"))
    assert [test_id] = flake.test_ids
    assert test_id =~ "test/flaky_test.exs:"
    assert is_integer(flake.seed)
    assert flake.seed >= 0

    assert Enum.any?(result.events, &(&1.event == "scope_warning" and &1.path == "README.md"))

    assert {:ok, report} = Build.report(result)

    decoded = :json.decode(report)
    assert [%{"test_ids" => [^test_id], "seed" => seed}] = decoded["excused_flakes"]
    assert seed == flake.seed
  end

  defp scenario_parent(context, name) do
    parent = Path.join(context.tmp_dir, name)
    File.mkdir_p!(parent)
    parent
  end

  defp options(seed_project), do: %Options{seed_project: seed_project}

  defp landing_script do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", ready_source("candidate", :ready)),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, review_text("accept", :accept))
    ]
  end

  defp landing_script("revise once") do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", ready_source("candidate", :ready)),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, review_text("revise once", :revise)),
      ScriptedProvider.edit(
        :develop,
        "lib/tiny_app.ex",
        "# revision: candidate",
        "# revision: reviewed"
      ),
      ScriptedProvider.answer(:develop, "Done after repair."),
      ScriptedProvider.answer(:review, review_text("accept", :accept))
    ]
  end

  defp red_acceptance_script do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", ready_source("zero", :wrong)),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.edit(:develop, "lib/tiny_app.ex", "revision: zero", "revision: one"),
      ScriptedProvider.answer(:develop, "Done after repair one."),
      ScriptedProvider.edit(:develop, "lib/tiny_app.ex", "revision: one", "revision: two"),
      ScriptedProvider.answer(:develop, "Done after repair two.")
    ]
  end

  defp ready_source(marker, value) do
    """
    defmodule TinyApp do
      # revision: #{marker}
      def value, do: :#{value}
    end
    """
  end

  defp flake_script do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", ready_source("candidate", :ready)),
      ScriptedProvider.write(:develop, "README.md", "Out-of-scope note.\n"),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, review_text("accept", :accept))
    ]
  end

  defp flaky_test_source do
    """
    defmodule TinyApp.FlakyTest do
      use ExUnit.Case, async: true

      test "candidate run flakes once while base remains red" do
        if TinyApp.value() == :ready do
          marker = System.fetch_env!("KOGEN_FLAKE_MARKER")

          if File.exists?(marker) do
            assert true
          else
            File.write!(marker, "seen")
            flunk("injected one-time Candidate test flake")
          end
        else
          assert TinyApp.value() == :ready
        end
      end
    end
    """
  end

  defp review_text("revise once", :revise),
    do: ~s({"verdict":"revise","findings":["A1: keep a clear implementation revision marker"]})

  defp review_text(_label, :accept), do: ~s({"verdict":"accept","findings":[]})
end
