defmodule Kogen.E2e.ApprovalSetupTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Engine.Runtime
  alias Kogen.Proc.Sandbox
  alias Kogen.Shaper
  alias Kogen.Shaper.Request
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @moduletag timeout: 300_000

  @slug "approval-setup"

  test "approval runs setup before its acceptance checks", %{tmp_dir: tmp_dir} do
    project = project!(tmp_dir)

    {:ok, runtime} = Kogen.Kernel.runtime()
    {:ok, project_config} = Kogen.Project.load(project)
    {:ok, env} = Kogen.Kernel.candidate_environment(project, runtime, project_config)
    env = Map.merge(env, %{"ERL_FLAGS" => "+S 1:1 +A 1", "MIX_ENV" => "test"})

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write_many(:shape, [
          {intent_path(), intent()},
          {acceptance_path(), acceptance_test()}
        ])
      ])

    config = %Config{server: server}

    try do
      assert {:ok, _result} = Shaper.shape(shape_request(project, tmp_dir, env, runtime, config))
      assert File.read!(Path.join(project, ".kogen/setup-ready")) == "fixture ready\n"

      File.rm!(Path.join(project, ".kogen/setup-ready"))
      refute File.exists?(Path.join(project, ".kogen/setup-ready"))

      approval_tmp = Runtime.temporary_directory(env)
      previous_logs = setup_logs(approval_tmp)

      assert {:ok, preview} =
               Kogen.Kernel.approval_preview(@slug, project, project, "main", nil)

      assert preview.approval.by == "Kogen Test <test@kogen.invalid>"
      assert File.read!(Path.join(project, ".kogen/setup-ready")) == "fixture ready\n"
      assert [setup_log] = setup_logs(approval_tmp) -- previous_logs
      assert File.read!(setup_log) =~ "approval-setup-ran"
      assert {:ok, _sha} = Kogen.Kernel.approve(preview)
      assert length(ScriptedProvider.requests(config)) == 1
    after
      GenServer.stop(server, :normal)
    end
  end

  defp shape_request(project, tmp_dir, env, runtime, config) do
    run_dir = Path.join(tmp_dir, "shape-run")
    home = Map.fetch!(runtime.base_env, "HOME")

    %Request{
      workdir: project,
      slug: @slug,
      task: "Define an acceptance test for Tiny.value/0 and its generated fixture.",
      model: "scripted-model",
      effort: "low",
      provider_mod: ScriptedProvider,
      provider_config: config,
      env: env,
      git_env: Git.env(),
      run_dir: run_dir,
      sandbox: %Sandbox{
        enabled:
          project_config_sandbox?(project) and not Runtime.sandboxed?(env) and
            not Runtime.sandboxed?(runtime),
        home: home,
        project_root: project,
        origin: project,
        workspace: project,
        run_dir: run_dir,
        tmp_dir: Runtime.temporary_directory(env),
        workspace_is_project: true
      }
    }
  end

  defp project_config_sandbox?(project) do
    {:ok, config} = Kogen.Project.load(project)
    config.sandbox
  end

  defp project!(tmp_dir) do
    project = Git.create!(Path.join(tmp_dir, "project"))

    write!(project, ".mise.toml", ~s([tools]\nelixir = "1.20.4-otp-29"\nerlang = "29.1.1"\n))
    write!(project, ".gitignore", "_build/\ndeps/\n.kogen/setup-ready\n")
    write!(project, "mix.exs", mix_project())
    write!(project, "lib/tiny.ex", "defmodule Tiny do\n  def value, do: :old\nend\n")
    write!(project, "test/test_helper.exs", "ExUnit.start()\n")
    write!(project, ".kogen/setup-source", "fixture ready\n")
    write!(project, ".kogen/project.yaml", project_config(tmp_dir))
    Git.git!(project, ["add", "--all"])
    Git.git!(project, ["commit", "--quiet", "-m", "Seed approval fixture"])
    Git.git!(project, ["branch", "-M", "main"])

    project
  end

  defp project_config(tmp_dir) do
    """
    name: approval_fixture
    env:
      TMPDIR: #{inspect(tmp_dir)}
    setup:
      - name: fixture
        argv: [sh, -c, 'cp .kogen/setup-source .kogen/setup-ready && echo approval-setup-ran']
        timeout_ms: 10000
    checks:
      - name: tests
        argv: [mix, test]
        timeout_ms: 120000
    acceptance_checks:
      - name: setup-required
        argv: [test, -s, .kogen/setup-ready]
        timeout_ms: 10000
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

  defp intent do
    """
    ---
    title: Keep Tiny value
    domains: [app]
    size: small
    ---
    Preserve the behavior of Tiny.value/0 while checking the generated setup fixture.

    ## Acceptance
    - A1: The setup fixture is available and Tiny.value/0 returns :ready on the unchanged checkout.

    ## Verify
    - A1: test

    ## Notes
    Approach: Keep Tiny.value/0 unchanged and preserve its public result while adding this required acceptance coverage.
    """
  end

  defp acceptance_test do
    """
    defmodule Tiny.Acceptance.ApprovalSetupTest do
      use ExUnit.Case, async: true

      @tag intent: "approval-setup/A1"
      test "the generated setup fixture is present and the proposal is implemented" do
        assert File.read!(".kogen/setup-ready") == "fixture ready\\n"
        assert Tiny.value() == :ready
      end
    end
    """
  end

  defp setup_logs(tmp_dir) do
    Path.wildcard(Path.join([tmp_dir, "kogen-approval", @slug, "*", "logs", "setup-fixture.log"]))
  end

  defp intent_path, do: ".kogen/intents/#{@slug}/intent.md"
  defp acceptance_path, do: ".kogen/acceptance/#{@slug}_test.exs"

  defp write!(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
