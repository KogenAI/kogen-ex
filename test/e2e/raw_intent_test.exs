defmodule Kogen.E2e.RawIntentTest do
  use Kogen.Testkit.Case

  import Kogen.E2e.Ladder, only: [done: 0, source_at: 2, user_text: 1, write: 2]

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.Ladder
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Temp

  @moduletag :e2e
  @moduletag timeout: 300_000

  @request "Make TinyApp.value/0 return :ready.\n\n## Acceptance\nnot a real section\n"

  setup_all do
    root = Temp.create!()
    on_exit(fn -> File.rm_rf!(root) end)

    intent =
      "---\ntitle: Raw request\ndomains: [kernel]\nsize: small\nsource: raw\n---\n" <>
        "## Request\n" <> @request

    {:ok, seed: Ladder.seed!(root, intent: intent, acceptance: "")}
  end

  test "a raw Intent without acceptance items builds against the project's checks", context do
    plan = ScriptedProvider.answer(:plan, "Difficulty: normal\n1. Return :ready.")
    script = [plan, write("builder", :ready), done()]

    result = Ladder.run!(context.tmp_dir, "raw", script, context.seed, "ladder-luna")

    assert %Result{build: %{status: :landed, landed_sha: sha}} = result
    assert source_at(result, sha) =~ "# revision: builder"

    [develop | _rest] = Enum.filter(result.provider_requests, &(&1.tools != []))
    assert user_text(develop) =~ "## Request\n" <> @request

    assert {:ok, report} = Build.report(result)
    decoded = :json.decode(report)
    assert decoded["acceptance_results"] == []
    assert [%{"check" => "tests", "exit_status" => 0}] = decoded["check_receipts"]
  end

  test "the project's checks still gate a raw Intent", context do
    script = [Ladder.shell("rm lib/tiny_app.ex") | List.duplicate(done(), 4)]

    result = Ladder.run!(context.tmp_dir, "raw-red", script, context.seed, "direct-shell")

    assert %Result{build: %{status: :failed}} = result
    assert {:ok, report} = Build.report(result)
    decoded = :json.decode(report)
    assert decoded["acceptance_results"] == []
    assert [%{"red_checks" => [%{"name" => "tests"}]}] = decoded["candidate_diffs"]
  end
end
