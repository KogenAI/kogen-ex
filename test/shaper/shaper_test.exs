defmodule Kogen.Shaper.Tests do
  @moduledoc false
  use Kogen.Testkit.Case

  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Proc.Sandbox
  alias Kogen.Shaper
  alias Kogen.Shaper.Request
  alias Kogen.Testkit.Git

  test "validation failure returns to the same scripted conversation for repair", %{
    tmp_dir: tmp_dir
  } do
    project = seed_project!(Path.join(tmp_dir, "project"))
    invalid_intent = intent("usually keeps", "A1 verifies Tiny.value/0 returns :old.")

    valid_intent =
      change_intent(
        "Approach: Change Tiny.value/0 to return :new and preserve its public function path."
      )

    test_source = String.replace(acceptance_test(), ":old", ":new")

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write(:shape, "README.md", "unauthorized\n"),
        ScriptedProvider.write(:shape, intent_path(), invalid_intent),
        ScriptedProvider.write(:shape, acceptance_path(), malformed_acceptance_test()),
        ScriptedProvider.write_many(:shape, [
          {intent_path(), valid_intent},
          {acceptance_path(), test_source}
        ])
      ])

    config = %Config{server: server}

    try do
      shape_request = request(project, tmp_dir, config)
      assert shape_request.limits == %{max_turns: 60, wall_ms: :infinity}
      assert {:ok, result} = Shaper.shape(shape_request)
      assert result.rounds == 3
      assert length(result.calls) == 4
      assert Enum.all?(result.calls, &(&1.model == "scripted-model" and is_integer(&1.wall_ms)))
      transcript = File.read!(result.transcript_path)
      assert transcript =~ "model_usage"
      assert transcript =~ "cached_input"
      assert transcript =~ "wall_ms"

      run_log =
        File.read!(Path.join([Path.dirname(result.transcript_path), "logs", "shaper.log"]))

      assert run_log =~ "attempt=1 started turns_used=0/60"
      assert run_log =~ "attempt=1 model_pass_complete"
      assert run_log =~ "attempt=1 validation_failed"
      assert run_log =~ "attempt=2 started turns_used=2/60"
      assert run_log =~ "attempt=2 validation_failed"
      assert run_log =~ "attempt=3 started turns_used=3/60"
      assert run_log =~ "attempt=3 validation_passed"

      assert File.read!(result.intent_path) ==
               valid_intent <> "\n## Request\n" <> shape_request.task

      assert File.read!(result.acceptance_path) == test_source
      refute File.exists?(Path.join(project, "README.md"))
      refute File.exists?(Path.join(project, "test/acceptance/shape-loop_test.exs"))

      requests = ScriptedProvider.requests(config)
      assert length(requests) == 4

      assert Enum.map_join(Enum.at(requests, 1).input, &inspect/1) =~
               "outside the shaper's two-file scope"

      assert Enum.map_join(Enum.at(requests, 0).input, &inspect/1) =~
               ".kogen/intents/shape-loop/intent.md"

      assert Enum.map_join(Enum.at(requests, 0).input, &inspect/1) =~
               ".kogen/acceptance/shape-loop_test.exs"

      assert Enum.map_join(Enum.at(requests, 0).input, &inspect/1) =~
               "Configured project domains: app"

      assert Enum.at(requests, 0).instructions =~ "Use this exact Intent structure"

      assert Enum.at(requests, 0).instructions =~ "Acceptance criteria alone are not a plan"
      assert Enum.at(requests, 0).instructions =~ "At least one item must use `test`"
      assert Enum.at(requests, 0).instructions =~ "title: Check acceptance tests at approval"

      assert Enum.at(requests, 0).instructions =~
               "title: Rebase onto a moved base instead of parking"

      assert Enum.map_join(Enum.at(requests, 1).input, &inspect/1) =~
               ".kogen/acceptance/shape-loop_test.exs"

      assert Enum.map_join(Enum.at(requests, 2).input, &inspect/1) =~ "intent_lint_failed"
      assert Enum.map_join(Enum.at(requests, 2).input, &inspect/1) =~ "contains a hedge"
      repair = Enum.map_join(Enum.at(requests, 2).input, &inspect/1)
      assert repair =~ "Acceptance item A1 text:"
      assert repair =~ "Tiny.value/0 usually keeps returning :old on the unchanged checkout."

      assert repair =~
               "Rule: Acceptance items must state a definite, observable result without hedge words."

      assert repair =~ "Notes text:"
      assert repair =~ "A1 verifies Tiny.value/0 returns :old."
      assert repair =~ "Notes must begin with `Approach:`"

      format_repair = Enum.map_join(Enum.at(requests, 3).input, &inspect/1)
      assert format_repair =~ "format_failed"
      assert format_repair =~ "TokenMissingError"

      assert Enum.all?(requests, fn request ->
               Enum.map(request.tools, &Map.get(&1, "name")) == ["read", "search", "write"]
             end)
    after
      GenServer.stop(server, :normal)
    end
  end

  test "formats an unformatted acceptance test and stops on the validating write turn", %{
    tmp_dir: tmp_dir
  } do
    project = seed_project!(Path.join(tmp_dir, "project"))

    valid_intent =
      change_intent(
        "Approach: Change Tiny.value/0 to return :new and preserve its public function path."
      )

    unformatted_test = """
    defmodule Tiny.Acceptance.ShapeLoopTest do
    use ExUnit.Case,async: true
    @tag intent: "shape-loop/A1"
    test "the existing public value remains available" do
    assert(Tiny.value()==:new)
    end
    end
    """

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write(:shape, acceptance_path(), unformatted_test),
        ScriptedProvider.write(:shape, intent_path(), valid_intent)
      ])

    config = %Config{server: server}

    try do
      assert {:ok, result} = Shaper.shape(request(project, tmp_dir, config))
      requests = ScriptedProvider.requests(config)

      assert result.rounds == 2
      assert length(result.calls) == 2
      assert length(requests) == 2
      assert ScriptedProvider.remaining(config) == 0

      assert File.read!(result.acceptance_path) ==
               String.replace(acceptance_test(), ":old", ":new")

      assert Enum.map_join(Enum.at(requests, 1).input, &inspect/1) =~
               "Cannot read .kogen/intents/shape-loop/intent.md"
    after
      GenServer.stop(server, :normal)
    end
  end

  test "uses the project format argv before validating the generated files", %{tmp_dir: tmp_dir} do
    project = seed_project!(Path.join(tmp_dir, "project"))
    formatter_script = Path.join(tmp_dir, "formatter.sh")
    calls_path = Path.join(tmp_dir, "formatter-calls.txt")

    File.write!(formatter_script, ~s(printf '%s\\n' "$@" >> "$KOGEN_FORMAT_CALLS"\n))

    File.write!(
      Path.join([project, ".kogen", "project.yaml"]),
      project_config(["/bin/sh", formatter_script])
    )

    valid_intent =
      change_intent(
        "Approach: Change Tiny.value/0 to return :new and preserve its public function path."
      )

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write_many(:shape, [
          {intent_path(), valid_intent},
          {acceptance_path(), String.replace(acceptance_test(), ":old", ":new")}
        ])
      ])

    config = %Config{server: server}

    try do
      shape_request = request(project, tmp_dir, config)

      shape_request = %{
        shape_request
        | env: Map.put(shape_request.env, "KOGEN_FORMAT_CALLS", calls_path)
      }

      assert {:ok, result} = Shaper.shape(shape_request)
      assert result.rounds == 1
      assert File.read!(calls_path) == acceptance_path() <> "\n"

      assert File.exists?(
               Path.join([tmp_dir, "shape-run", "logs", "shape-acceptance-1-format.log"])
             )
    after
      GenServer.stop(server, :normal)
    end
  end

  test "skips a missing formatter with a warning and still runs format acceptance", %{
    tmp_dir: tmp_dir
  } do
    project = seed_project!(Path.join(tmp_dir, "project"))

    File.write!(
      Path.join([project, ".kogen", "project.yaml"]),
      project_config([Path.join(tmp_dir, "missing-formatter")])
    )

    valid_intent =
      change_intent(
        "Approach: Change Tiny.value/0 to return :new and preserve its public function path."
      )

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write_many(:shape, [
          {intent_path(), valid_intent},
          {acceptance_path(), String.replace(acceptance_test(), ":old", ":new")}
        ])
      ])

    config = %Config{server: server}

    try do
      assert {:ok, result} = Shaper.shape(request(project, tmp_dir, config))
      assert result.rounds == 1
      assert length(ScriptedProvider.requests(config)) == 1

      format_log = File.read!(Path.join([tmp_dir, "shape-run", "logs", "shape-format.log"]))
      assert format_log =~ "WARNING: environment/tool_missing"
      assert format_log =~ "Skipping controller formatting"

      assert File.exists?(
               Path.join([tmp_dir, "shape-run", "logs", "shape-acceptance-1-format.log"])
             )

      shaper_log = File.read!(Path.join([tmp_dir, "shape-run", "logs", "shaper.log"]))
      assert shaper_log =~ "warning formatter_skipped reason=tool_missing"
    after
      GenServer.stop(server, :normal)
    end
  end

  defp request(project, tmp_dir, %Config{} = config) do
    {:ok, runtime} = Kogen.Kernel.runtime()
    {:ok, project_config} = Kogen.Project.load(project)
    {:ok, env} = Kogen.Kernel.candidate_environment(project, runtime, project_config)
    run_dir = Path.join(tmp_dir, "shape-run")

    %Request{
      workdir: project,
      slug: "shape-loop",
      task: "Change Tiny.value/0 to return :new while preserving its public function.",
      model: "scripted-model",
      effort: "low",
      provider_mod: ScriptedProvider,
      provider_config: config,
      env: Map.merge(env, %{"MIX_ENV" => "test", "ERL_FLAGS" => "+S 1:1 +A 1"}),
      git_env: Git.env(),
      run_dir: run_dir,
      sandbox: %Sandbox{
        enabled: project_config.sandbox and not Map.get(runtime, :sandboxed, false),
        home: runtime.base_env["HOME"],
        project_root: project,
        origin: project,
        workspace: project,
        run_dir: run_dir,
        tmp_dir: Map.get(env, "TMPDIR", "/tmp"),
        workspace_is_project: true
      }
    }
  end

  defp seed_project!(project) do
    File.mkdir_p!(Path.join(project, ".kogen"))
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(Path.join(project, "test"))
    File.write!(Path.join(project, "mix.exs"), mix_project())

    File.write!(
      Path.join(project, "lib/tiny.ex"),
      "defmodule Tiny do\n  def value, do: :old\nend\n"
    )

    File.write!(Path.join(project, "test/test_helper.exs"), "ExUnit.start()\n")
    File.write!(Path.join(project, ".gitignore"), "_build/\ndeps/\ncover/\n")
    File.write!(Path.join(project, ".kogen/project.yaml"), project_config())
    Git.git!(project, ["init", "--quiet", "--template="])
    Git.git!(project, ["add", "--all"])
    Git.git!(project, ["commit", "--quiet", "-m", "Seed shaper fixture"])
    project
  end

  defp mix_project do
    """
    defmodule Tiny.MixProject do
      use Mix.Project

      def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.20"]
    end
    """
  end

  defp project_config(format_argv \\ nil) do
    format_config =
      if format_argv do
        "format: [" <> Enum.map_join(format_argv, ", ", &inspect/1) <> "]\n"
      else
        ""
      end

    """
    name: tiny
    #{format_config}checks:
      - name: tests
        argv: [mix, test]
        timeout_ms: 120000
    acceptance_checks:
      - name: format
        argv: [mix, format, --check-formatted, "{path}"]
        timeout_ms: 120000
    domains:
      app: [lib, test]
    """
  end

  defp intent(acceptance_text, notes) do
    notes_section = if notes, do: "\n\n## Notes\n#{notes}\n", else: ""

    String.trim_leading("""
    ---
    title: Keep Tiny value
    domains: [app]
    size: small
    ---
    Keep the existing public Tiny.value/0 result.

    ## Acceptance
    - A1: Tiny.value/0 #{acceptance_text} returning :old on the unchanged checkout.

    ## Verify
    - A1: test keep domain=app
    #{notes_section}
    """)
  end

  defp change_intent(notes) do
    "keeps"
    |> intent(notes)
    |> String.replace(
      "Tiny.value() keeps returning :old on the unchanged checkout.",
      "Tiny.value() returns :new on the unchanged checkout."
    )
    |> String.replace("test keep domain=app", "test domain=app")
  end

  defp acceptance_test do
    """
    defmodule Tiny.Acceptance.ShapeLoopTest do
      use ExUnit.Case, async: true
      @tag intent: "shape-loop/A1"
      test "the existing public value remains available" do
        assert(Tiny.value() == :old)
      end
    end
    """
  end

  defp malformed_acceptance_test do
    """
    defmodule Tiny.Acceptance.ShapeLoopTest do
      use ExUnit.Case, async: true
      test "broken syntax" do
    """
  end

  defp intent_path, do: ".kogen/intents/shape-loop/intent.md"
  defp acceptance_path, do: ".kogen/acceptance/shape-loop_test.exs"
end
