defmodule Kogen.E2e.RailsBuildTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Engine.Build.Request, as: BuildRequest
  alias Kogen.Kernel.Approval
  alias Kogen.Proc
  alias Kogen.Proc.Sandbox
  alias Kogen.Shaper
  alias Kogen.Shaper.Request
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Rails

  @moduletag :e2e
  @moduletag timeout: 300_000
  @moduletag skip: Rails.unavailable_reason()
  @slug "rails-greeting"
  @controller "app/controllers/greetings_controller.rb"

  test "Minitest acceptance shapes, approves, gates and lands a Rails request offline", %{
    tmp_dir: tmp_dir
  } do
    project = Rails.project!(Path.join(tmp_dir, "project"))
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)
    runtime = Rails.runtime!(project, home)
    workspace_root = Kogen.Kernel.workspace_root(project, home)
    File.ln_s!(Path.join(workspace_root, "runs"), Path.join(project, ".kogen/runs"))
    {:ok, profile} = Kogen.Project.load(project)
    {:ok, env} = Kogen.Kernel.candidate_environment(project, runtime, profile)

    source =
      project
      |> Path.join(@controller)
      |> File.read!()
      |> String.replace(~s("old"), ~s("new"))

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write_many(:shape, [
          {".kogen/intents/#{@slug}/intent.md", intent()},
          {".kogen/acceptance/#{@slug}_test.rb", acceptance()}
        ]),
        ScriptedProvider.write(:develop, @controller, source),
        ScriptedProvider.finish()
      ])

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    config = %Config{server: server}
    run_dir = Path.join(tmp_dir, "shape-run")

    request = %Request{
      workdir: project,
      slug: @slug,
      task: "Return new from GET /greeting, preserving its successful HTTP status.",
      model: "scripted-model",
      effort: "high",
      provider_mod: ScriptedProvider,
      provider_config: config,
      env: env,
      git_env: Git.env(),
      run_dir: run_dir,
      sandbox: sandbox(project, home, run_dir, tmp_dir)
    }

    assert {:ok, %ProcResult{exit_status: 0, output_tail: "1\n"}} =
             Proc.run(["sqlite3", ":memory:", "select 1;"],
               cd: project,
               env: env,
               sandbox: request.sandbox
             )

    assert {:ok, shaped} = Shaper.shape(request)
    assert shaped.acceptance_path == Path.join(project, ".kogen/acceptance/#{@slug}_test.rb")
    assert File.read!(shaped.acceptance_path) == acceptance()
    refute File.exists?(Path.join(project, "test/acceptance/#{@slug}_test.rb"))

    Git.git!(project, ["add", ".kogen"])
    Git.git!(project, ["commit", "--quiet", "-m", "Shape Rails request"])

    assert {:ok, preview} = Approval.prepare(@slug, project, project, "main", "Kogen Test", env)
    assert {:ok, _sha} = Kogen.Kernel.approve(preview)

    assert {:ok, build} =
             Kogen.Kernel.build(%BuildRequest{
               slug: @slug,
               home: home,
               project_root: project,
               workspace_root: workspace_root,
               origin: project,
               base: "main",
               model: "scripted-model",
               effort: "low",
               recipe: Kogen.Engine.build_recipe("direct", "scripted-model", "low"),
               runtime: runtime,
               provider_mod: ScriptedProvider,
               provider_config: config,
               credential_source: :custom,
               credential_label: "scripted"
             })

    assert build.status == :landed
    assert Git.git!(project, ["show", "#{build.landed_sha}:#{@controller}"]) =~ ~s("new")

    assert Git.git!(project, ["show", "#{build.landed_sha}:test/acceptance/#{@slug}_test.rb"]) ==
             acceptance()

    landed_paths = Git.git!(project, ["show", "--pretty=", "--name-only", build.landed_sha])
    refute landed_paths =~ ".bundle/"
    refute landed_paths =~ "vendor/bundle/"

    assert {:ok, report} = Kogen.Kernel.report(@slug, project, project, "main")
    decoded = :json.decode(report)
    assert Enum.all?(decoded["acceptance_results"], &(&1["status"] == "passed"))
    assert length(decoded["acceptance_results"]) == 2

    [shape | _build_requests] = ScriptedProvider.requests(config)
    assert shape.instructions =~ "Minitest"
    assert shape.instructions =~ "test_A<n>_outcome"
    assert ScriptedProvider.remaining(config) == 0
  end

  defp sandbox(project, home, run_dir, tmp_dir) do
    %Sandbox{
      enabled: true,
      home: home,
      project_root: project,
      origin: project,
      workspace: project,
      run_dir: run_dir,
      tmp_dir: tmp_dir,
      workspace_is_project: true
    }
  end

  defp intent do
    """
    ---
    title: Return the new greeting
    domains: [app]
    size: small
    ---
    Change the greeting response while preserving successful requests.

    ## Acceptance
    - A1: GET /greeting returns new.
    - A2: GET /greeting remains successful.

    ## Verify
    - A1: test domain=app
    - A2: test keep domain=app

    ## Notes
    Approach: Change GreetingsController#show to render new while preserving its successful HTTP status.
    """
  end

  defp acceptance do
    """
    require "test_helper"

    class GreetingAcceptanceTest < ActionDispatch::IntegrationTest
      test "A1 greeting changes" do
        get "/greeting"
        assert_equal "new", response.body
      end

      test "A2 greeting remains successful" do
        get "/greeting"
        assert_response :success
      end
    end
    """
  end
end
