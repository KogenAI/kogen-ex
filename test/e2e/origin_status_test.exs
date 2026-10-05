defmodule Kogen.E2e.OriginStatusTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build.Environment
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Engine.Build.Request
  alias Kogen.Kernel.CLI
  alias Kogen.Proc.Sandbox
  alias Kogen.Shaper
  alias Kogen.Shaper.Request, as: ShapeRequest
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @tag timeout: 120_000
  @slug "origin-status"

  test "status and report read the separate origin without fetching", %{tmp_dir: tmp_dir} do
    parent = Path.join(tmp_dir, "origin-status")
    project = Path.join(parent, "project")
    origin = Path.join(parent, "origin.git")
    home = Path.join(parent, "test-home")
    seed_project!(project, origin)

    workspace_root = Kogen.Kernel.workspace_root(project, home)
    File.mkdir_p!(Path.join(project, ".kogen"))
    File.ln_s!(Path.join(workspace_root, "runs"), Path.join(project, ".kogen/runs"))

    runtime = Environment.runtime!(project, home)
    {:ok, project_config} = Kogen.Project.load(project)
    {:ok, env} = Kogen.Kernel.candidate_environment(project, runtime, project_config)

    shape_server = start_shape_server()

    try do
      assert {:ok, _shape} =
               Shaper.shape(shape_request(project, origin, parent, home, env, shape_server))
    after
      GenServer.stop(shape_server, :normal)
    end

    assert {:ok, preview} =
             Kogen.Kernel.Approval.prepare(
               @slug,
               project,
               origin,
               "main",
               "Kogen Test",
               env
             )

    assert preview.origin == origin
    assert {:ok, _approval_sha} = Kogen.Kernel.approve(preview)

    {0, approved_json} =
      CLI.execute(["status", "--project", project, "--base", "main", "--json"])

    assert [%{"landed_sha" => :null, "slug" => @slug, "status" => "approved"}] =
             Enum.filter(:json.decode(approved_json), &(&1["slug"] == @slug))

    build_server = start_build_server()

    try do
      assert {:ok, build} =
               Kogen.Kernel.build(build_request(project, origin, home, runtime, build_server))

      assert build.status == :landed

      base_sha = project |> Git.git!(["rev-parse", "refs/remotes/origin/main"]) |> String.trim()
      assert base_sha == project |> Git.git!(["rev-parse", "refs/heads/main"]) |> String.trim()

      assert origin |> Git.git!(["rev-parse", "refs/heads/main"]) |> String.trim() ==
               build.landed_sha

      assert {:ok, [status]} =
               Kogen.Kernel.Status.list(project, workspace_root, origin, "main", Git.env())

      assert status.status == :landed
      assert status.run_id == build.run_id
      assert status.landed_sha == build.landed_sha

      {0, status_json} =
        CLI.execute(["status", "--project", project, "--base", "main", "--json"])

      assert [
               %{
                 "landed_sha" => landed_sha,
                 "run_id" => run_id,
                 "slug" => @slug,
                 "status" => "landed"
               }
             ] =
               Enum.filter(:json.decode(status_json), &(&1["slug"] == @slug))

      assert landed_sha == build.landed_sha
      assert run_id == build.run_id

      {0, report_json} =
        CLI.execute([
          "build",
          "show",
          @slug,
          "--json",
          "--project",
          project,
          "--base",
          "main"
        ])

      assert %{"landed_sha" => ^landed_sha, "status" => "landed"} = :json.decode(report_json)
    after
      GenServer.stop(build_server, :normal)
    end
  end

  defp seed_project!(project, origin) do
    Git.bare!(origin)
    File.mkdir_p!(Path.join(project, ".kogen"))
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(Path.join(project, "test"))

    File.write!(Path.join(project, ".gitignore"), "_build/\ndeps/\n")

    File.write!(
      Path.join(project, ".mise.toml"),
      ~s([tools]\nelixir = "1.20.4-otp-29"\nerlang = "29.1.1"\n)
    )

    File.write!(Path.join(project, "mix.exs"), mix_project())

    File.write!(
      Path.join(project, "lib/tiny_app.ex"),
      "defmodule TinyApp do\n  def value, do: :base\nend\n"
    )

    File.write!(Path.join(project, "test/test_helper.exs"), "ExUnit.start()\n")
    File.write!(Path.join(project, ".kogen/project.yaml"), project_config())

    Git.git!(project, ["init", "--quiet", "--template="])
    Git.git!(project, ["add", "--all"])
    Git.git!(project, ["commit", "--quiet", "-m", "Seed origin status fixture"])
    Git.git!(project, ["branch", "-M", "main"])
    Git.git!(project, ["remote", "add", "origin", origin])
    Git.git!(project, ["push", "--quiet", "--set-upstream", "origin", "main"])
    :ok
  end

  defp start_shape_server do
    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write_many(:shape, [
          {".kogen/intents/#{@slug}/intent.md", intent()},
          {".kogen/acceptance/#{@slug}_test.exs", acceptance_test()}
        ])
      ])

    server
  end

  defp start_build_server do
    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write(
          :develop,
          "lib/tiny_app.ex",
          "defmodule TinyApp do\n  def value, do: :ready\nend\n"
        ),
        ScriptedProvider.answer(:develop, "Done.")
      ])

    server
  end

  defp shape_request(project, origin, parent, home, env, server) do
    run_dir = Path.join(parent, "shape-run")

    %ShapeRequest{
      workdir: project,
      slug: @slug,
      task: "Make TinyApp.value/0 return :ready.",
      model: "scripted-model",
      effort: "medium",
      provider_mod: ScriptedProvider,
      provider_config: %Config{server: server},
      env: env,
      git_env: Git.env(),
      run_dir: run_dir,
      sandbox: %Sandbox{
        enabled: false,
        home: home,
        project_root: project,
        origin: origin,
        workspace: project,
        run_dir: run_dir,
        tmp_dir: parent,
        workspace_is_project: true
      }
    }
  end

  defp build_request(project, origin, home, runtime, server) do
    %Request{
      slug: @slug,
      home: home,
      project_root: project,
      workspace_root: Kogen.Kernel.workspace_root(project, home),
      origin: origin,
      base: "main",
      model: "scripted-model",
      effort: "medium",
      recipe: Kogen.Engine.build_recipe("direct", "scripted-model", "medium"),
      runtime: runtime,
      provider_mod: ScriptedProvider,
      provider_config: %Config{server: server},
      credential_source: :custom,
      credential_label: "test"
    }
  end

  defp intent do
    """
    ---
    title: Return a ready value
    domains: [kernel]
    size: small
    ---
    Make TinyApp.value/0 return :ready.

    ## Acceptance
    - A1: TinyApp.value/0 returns :ready.

    ## Verify
    - A1: test

    ## Notes
    Approach: Update TinyApp.value/0 in lib/tiny_app.ex to return :ready while preserving the public function.
    """
  end

  defp acceptance_test do
    """
    defmodule TinyApp.OriginStatusAcceptanceTest do
      use ExUnit.Case, async: true

      @tag intent: "origin-status/A1"
      test "returns the ready value" do
        assert TinyApp.value() == :ready
      end
    end
    """
  end

  defp mix_project do
    """
    defmodule TinyApp.MixProject do
      use Mix.Project

      def project, do: [app: :tiny_app, version: "0.1.0", elixir: "~> 1.20"]
      def application, do: [extra_applications: [:logger]]
    end
    """
  end

  defp project_config do
    """
    name: tiny_app
    format: [mix, format]
    checks:
      - name: tests
        argv: [mix, test]
        timeout_ms: 60000
    fix: []
    domains:
      kernel: [lib, test]
    """
  end
end
