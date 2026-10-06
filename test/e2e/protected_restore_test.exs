defmodule Kogen.E2e.ProtectedRestoreTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @moduletag timeout: 300_000

  test "a shell edit to approved tests and Intent is repaired before checks", %{tmp_dir: tmp_dir} do
    parent = Path.join(tmp_dir, "protected-shell-edits")
    File.mkdir_p!(parent)
    seed_project = Build.prepare_seed!(parent)

    shell_edit = """
    printf 'corrupted intent\\n' > .kogen/intents/build-engine/intent.md
    printf 'corrupted source acceptance\\n' > .kogen/acceptance/build-engine_test.exs
    printf 'corrupted candidate acceptance\\n' > test/acceptance/build-engine_test.exs
    """

    implementation_fix = """
    cat > lib/tiny_app.ex <<'EOF'
    #{ready_source()}EOF
    """

    result =
      Build.run!(
        parent,
        [
          ScriptedProvider.call(:develop, "shell", %{"cmd" => shell_edit}),
          ScriptedProvider.call(:develop, "shell", %{"cmd" => implementation_fix}),
          ScriptedProvider.answer(:develop, "Done after the protected paths were restored.")
        ],
        %Options{seed_project: seed_project, recipe: "direct-shell"}
      )

    assert %Result{build: %{status: :landed, landed_sha: landed_sha}, run_status: :landed} =
             result

    restored_paths =
      result.events
      |> Enum.filter(&(&1.event == "protected_restored"))
      |> Enum.map(& &1.path)
      |> Enum.sort()

    assert restored_paths ==
             [
               ".kogen/acceptance/build-engine_test.exs",
               ".kogen/intents/build-engine/intent.md",
               "test/acceptance/build-engine_test.exs"
             ]

    landed_files =
      result.fixture.origin
      |> Git.git!(["ls-tree", "-r", "--name-only", landed_sha])
      |> String.split("\n", trim: true)

    refute ".kogen/acceptance/build-engine_test.exs" in landed_files

    for path <- [
          ".kogen/intents/build-engine/intent.md",
          "test/acceptance/build-engine_test.exs"
        ] do
      approved_path =
        if path == "test/acceptance/build-engine_test.exs",
          do: ".kogen/acceptance/build-engine_test.exs",
          else: path

      actual =
        if path == "test/acceptance/build-engine_test.exs" do
          Git.git!(result.fixture.origin, ["show", "#{landed_sha}:#{path}"])
        else
          File.read!(Path.join(result.fixture.project_root, path))
        end

      assert actual == File.read!(Path.join(seed_project, approved_path))
    end

    [_edit_request, correction_request, _done_request] = result.provider_requests

    assert Enum.any?(correction_request.input, fn item ->
             String.contains?(inspect(item), "acceptance tests and the Intent are read-only")
           end)
  end

  defp ready_source do
    """
    defmodule TinyApp do
      # revision: protected-restore
      def value, do: :ready
    end
    """
  end
end
