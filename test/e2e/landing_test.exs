defmodule Kogen.E2e.LandingTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @tag timeout: 120_000

  setup_all do
    {:ok, seed_project: Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)}
  end

  test "lands into a clean checkout of the base branch and updates it", context do
    parent = scenario_parent(context, "clean-checkout")
    options = %Options{seed_project: context.seed_project, origin_checkout: :clean}
    result = Build.run!(parent, landing_script(), options)
    origin = result.fixture.origin

    assert %Result{build: %{status: :landed, landed_sha: sha} = build, run_status: :landed} =
             result

    assert origin |> Git.git!(["rev-parse", "refs/heads/main"]) |> String.trim() == sha
    assert origin |> Git.git!(["rev-parse", "HEAD"]) |> String.trim() == sha
    assert File.read!(Path.join(origin, "lib/tiny_app.ex")) =~ "def value, do: :ready"
    assert Git.git!(origin, ["status", "--porcelain"]) == ""
    refute Enum.any?(build.lines, &String.contains?(&1, "warning"))
    refute Enum.any?(result.events, &(&1.event == "landing_warning"))
  end

  test "lands into a dirty checkout, leaves it untouched, and warns", context do
    parent = scenario_parent(context, "dirty-checkout")
    options = %Options{seed_project: context.seed_project, origin_checkout: :dirty}
    result = Build.run!(parent, landing_script(), options)
    origin = result.fixture.origin
    local = File.read!(Path.join(origin, "lib/tiny_app.ex"))

    assert %Result{build: %{status: :landed, landed_sha: sha} = build, run_status: :landed} =
             result

    assert origin |> Git.git!(["rev-parse", "refs/heads/main"]) |> String.trim() == sha
    assert local =~ "# local edit"
    assert local =~ "def value, do: :base"

    expected =
      "landed #{sha} on main; your checkout at #{canonical(origin)} has local changes and " <>
        "was not updated; run `git reset --keep #{sha}`, or merge it yourself"

    assert ("land: warning: " <> expected) in Enum.map(build.lines, &canonical/1)
    assert [event] = Enum.filter(result.events, &(&1.event == "landing_warning"))
    assert canonical(event.detail) == expected

    assert {:ok, report} = Build.report(result)

    assert %{"findings" => [%{"type" => "landing_warning", "message" => message}]} =
             :json.decode(report)

    assert canonical(message) == expected
  end

  test "a landing failure is a controller or environment failure, never a builder repair",
       context do
    parent = scenario_parent(context, "landing-failure")
    options = %Options{seed_project: context.seed_project, move_base_on: {:lock_base, :review}}
    result = Build.run!(parent, landing_script(), options)

    assert %Result{build: %{status: :failed, failure: failure}, run_status: :failed} = result
    assert %{class: :environment, reason: :landing_failed} = failure
    assert failure.detail =~ "ref_locked"
    assert result.claim_released
    refute Enum.any?(result.events, &(&1.event == "repair"))

    assert [_develop] =
             Enum.filter(result.events, &(&1.event == "model_stage" and &1.stage == "develop"))
  end

  defp scenario_parent(context, name) do
    parent = Path.join(context.tmp_dir, name)
    File.mkdir_p!(parent)
    parent
  end

  defp landing_script do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", ready_source()),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]
  end

  defp ready_source do
    """
    defmodule TinyApp do
      # revision: candidate
      def value, do: :ready
    end
    """
  end

  # Git and the Build report macOS temporary directories by their canonical /private path.
  defp canonical(path), do: String.replace(path, "/private/var/", "/var/")
end
