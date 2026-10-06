defmodule Kogen.Workspace.CandidateGuardTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Project
  alias Kogen.Testkit.Git
  alias Kogen.Workspace

  setup %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    base = repo |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()

    intent = %Intent{
      slug: "guard",
      title: "Guard",
      size: :small,
      brief: "Validate Candidate paths.",
      acceptance: [],
      domains: ["workspace", "engine"],
      notes: nil,
      path: ".kogen/intents/guard/intent.md",
      sha256: String.duplicate("a", 64)
    }

    project = %Project{
      root: repo,
      name: "guard",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{"engine" => ["lib/engine/"], "workspace" => ["lib/workspace"]}
    }

    {:ok, repo: repo, base: base, intent: intent, project: project}
  end

  test "allows domain and installed Intent paths and sorts remaining warnings", data do
    paths = [
      "lib/engine/in_scope.ex",
      "lib/workspace/in_scope.ex",
      ".kogen/intents/guard/intent.md",
      ".kogen/acceptance/guard_test.exs",
      "test/acceptance/guard_test.exs",
      "z.txt",
      "lib/engine_extra/outside.ex",
      ".kogen/intents/guard_extra/intent.md"
    ]

    for path <- paths do
      full_path = Path.join(data.repo, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, "changed\n")
    end

    assert {:ok, warnings} =
             Workspace.scope_warnings(data.repo, data.base, data.intent, data.project, Git.env())

    assert Enum.map(warnings, & &1.path) == [
             ".kogen/intents/guard_extra/intent.md",
             "lib/engine_extra/outside.ex",
             "z.txt"
           ]

    for warning <- warnings do
      assert warning.declared_domains == ["engine", "workspace"]

      assert warning.finding ==
               "Scope warning: #{warning.path} is outside the Intent's declared domains " <>
                 "[engine, workspace]."
    end
  end

  test "inspection errors remain controller failures", data do
    assert {:error, %Failure{class: :controller, reason: :workspace_failed, detail: protected}} =
             Workspace.check_candidate(data.repo, "missing-base", %{}, Git.env())

    assert protected =~ "Cannot inspect protected paths:"

    assert {:error, %Failure{class: :controller, reason: :workspace_failed, detail: scope}} =
             Workspace.scope_warnings(
               data.repo,
               "missing-base",
               data.intent,
               data.project,
               Git.env()
             )

    assert scope =~ "Cannot inspect scope paths:"
  end
end
