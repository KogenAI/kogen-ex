defmodule Kogen.E2e.FinalFixPassTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @moduletag timeout: 180_000

  test "a moved-base final fix is checked, recorded and committed before landing", %{tmp_dir: tmp} do
    seed = seed(tmp)

    result =
      Build.run!(Path.join(tmp, "build"), script(), %Options{
        seed_project: seed,
        move_base_on: fn
          fixture, :review ->
            File.write!(Path.join(fixture.project_root, "moved.txt"), "new base")
            Git.git!(fixture.project_root, ["add", "moved.txt"])
            Git.git!(fixture.project_root, ["commit", "-m", "Advance base"])
            Git.git!(fixture.project_root, ["push", "origin", "main"])
            :ok

          _, _ ->
            :skip
        end
      })

    assert result.build.status == :landed, inspect(result.build, limit: :infinity)
    origin = result.fixture.origin
    sha = result.build.landed_sha
    assert Git.git!(origin, ["show", "#{sha}:formatted.txt"]) == "integrated"
    tree = String.trim(Git.git!(origin, ["rev-parse", "#{sha}^{tree}"]))
    check = result.events |> Enum.filter(&(&1.event == "check_result")) |> List.last()
    assert Enum.all?(check.receipts, &(&1["tree"] == tree))
    assert Enum.any?(check.receipts, &(&1["check"] == "fix/format" and &1["exit_status"] == 0))
    assert {:ok, report} = Build.report(result)
    assert Enum.any?(:json.decode(report)["check_receipts"], &(&1["check"] == "fix/format"))
  end

  test "changes made after the recorded verification cannot land", %{tmp_dir: tmp} do
    result =
      Build.run!(Path.join(tmp, "build"), script(), %Options{
        seed_project: seed(tmp),
        move_base_on: fn
          fixture, :review ->
            [path] = Path.wildcard(Path.join(fixture.workspace_root, "**/formatted.txt"))
            File.write!(path, "after verification")
            :ok

          _, _ ->
            :skip
        end
      })

    refute result.build.status == :landed
    assert Enum.any?(result.events, &((&1.detail || "") =~ "unverified_tree"))

    assert String.trim(Git.git!(result.fixture.origin, ["rev-parse", "main"])) ==
             result.fixture.approved_base
  end

  defp seed(tmp) do
    Build.prepare_seed!(tmp,
      project_config: """
      name: tiny_app
      checks:
        - name: formatted
          argv: [test, -s, formatted.txt]
          timeout_ms: 60000
      fix:
        - name: format
          argv: [sh, -c, 'if test -f moved.txt; then printf integrated > formatted.txt; else printf candidate > formatted.txt; fi; echo formatted']
          timeout_ms: 60000
      domains:
        kernel: [lib, formatted.txt]
      """
    )
  end

  defp script do
    [
      ScriptedProvider.answer(:context, "Update TinyApp."),
      ScriptedProvider.answer(:plan, "Return ready."),
      ScriptedProvider.write(
        :develop,
        "lib/tiny_app.ex",
        "defmodule TinyApp do\n def value, do: :ready\nend\n"
      ),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]
  end
end
