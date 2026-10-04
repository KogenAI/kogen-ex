defmodule Kogen.Shaper.AcceptanceCommandExitTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.Failure
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Proc.Sandbox
  alias Kogen.Shaper
  alias Kogen.Shaper.Request
  alias Kogen.Testkit.Git

  test "does not repair acceptance command-unavailable statuses", %{tmp_dir: tmp_dir} do
    for status <- [126, 127] do
      project = seed_project!(Path.join(tmp_dir, "project-#{status}"), status)
      valid_intent = change_intent()

      {:ok, server} =
        ScriptedProvider.start_link([
          ScriptedProvider.write_many(:shape, [
            {intent_path(), valid_intent},
            {acceptance_path(), acceptance_test()}
          ])
        ])

      config = %Config{server: server}

      try do
        assert {:error, %Failure{class: :environment, reason: :tool_missing}} =
                 Shaper.shape(request(project, tmp_dir, config))

        assert length(ScriptedProvider.requests(config)) == 1
      after
        GenServer.stop(server, :normal)
      end
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
        enabled: project_config.sandbox and not runtime.sandboxed,
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

  defp seed_project!(project, status) do
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
    File.write!(Path.join(project, ".kogen/project.yaml"), project_config(status))
    Git.git!(project, ["init", "--quiet", "--template="])
    Git.git!(project, ["add", "--all"])
    Git.git!(project, ["commit", "--quiet", "-m", "Seed shaper fixture"])
    project
  end

  defp project_config(status) do
    """
    name: tiny
    checks:
      - name: tests
        argv: ["/bin/true"]
        timeout_ms: 120000
    acceptance_checks:
      - name: compile
        argv: ["/bin/sh", "-c", "exit #{status}"]
        timeout_ms: 120000
    domains:
      app: [lib, test]
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

  defp change_intent do
    """
    ---
    title: Keep Tiny value
    domains: [app]
    size: small
    ---
    Keep the existing public Tiny.value/0 result.

    ## Acceptance
    - A1: Tiny.value/0 returns :new on the unchanged checkout.

    ## Verify
    - A1: test domain=app

    ## Notes
    Approach: Change Tiny.value/0 to return :new and preserve its public function path.
    """
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

  defp intent_path, do: ".kogen/intents/shape-loop/intent.md"
  defp acceptance_path, do: ".kogen/acceptance/shape-loop_test.exs"
end
