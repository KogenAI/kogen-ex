defmodule Kogen.Shaper.RepairReliabilityTest do
  @moduledoc false
  use Kogen.Testkit.Case

  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Proc.Sandbox
  alias Kogen.Shaper
  alias Kogen.Shaper.Request
  alias Kogen.Testkit.Git

  test "normalizes an actionable Notes paragraph to Approach without a repair", %{
    tmp_dir: tmp_dir
  } do
    project = seed_project!(Path.join(tmp_dir, "project"))

    unlabeled =
      change_intent("Change Tiny.value/0 to return :new and preserve its public function path.")

    changed_test = String.replace(acceptance_test(), ":old", ":new")

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write_many(:shape, [
          {intent_path(), unlabeled},
          {acceptance_path(), changed_test}
        ])
      ])

    config = %Config{server: server}

    try do
      assert {:ok, result} = Shaper.shape(request(project, tmp_dir, config))
      assert result.rounds == 1
      assert length(result.calls) == 1

      assert File.read!(result.intent_path) =~
               "## Notes\nApproach: Change Tiny.value/0 to return :new and preserve its public function path."

      assert File.read!(Path.join([tmp_dir, "shape-run", "logs", "shaper.log"])) =~
               "normalized intent approach label"
    after
      GenServer.stop(server, :normal)
    end
  end

  test "repair exhaustion reports the actual failure and pass counts", %{tmp_dir: tmp_dir} do
    project = seed_project!(Path.join(tmp_dir, "project"))

    invalid =
      intent(
        "usually keeps",
        "Approach: Keep Tiny.value/0 unchanged and preserve its public result by avoiding unrelated changes."
      )

    repeated =
      ScriptedProvider.write_many(:shape, [
        {intent_path(), invalid},
        {acceptance_path(), acceptance_test()}
      ])

    {:ok, server} = ScriptedProvider.start_link(List.duplicate(repeated, 5))
    config = %Config{server: server}

    try do
      assert {:error,
              %Kogen.Contracts.Failure{
                class: :candidate,
                reason: :intent_lint_failed,
                detail: detail
              }} = Shaper.shape(request(project, tmp_dir, config))

      assert detail =~ "Shaper repair limit reached for intent_lint_failed"
      assert detail =~ "4 repair round(s), 5 attempt(s), and 5 model call(s)"
      assert detail =~ "candidate/intent_lint_failed"

      assert File.read!(Path.join([tmp_dir, "shape-run", "logs", "shaper.log"])) =~
               "repairs=4/4 attempts=5 calls=5"
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

  defp mix_project do
    """
    defmodule Tiny.MixProject do
      use Mix.Project
      def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.20"]
    end
    """
  end

  defp project_config do
    """
    name: tiny
    checks:
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

  defp intent_path, do: ".kogen/intents/shape-loop/intent.md"
  defp acceptance_path, do: ".kogen/acceptance/shape-loop_test.exs"
end
