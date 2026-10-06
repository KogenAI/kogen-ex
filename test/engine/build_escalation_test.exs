defmodule Kogen.Engine.BuildEscalationTest do
  use Kogen.Testkit.Case

  alias Kogen.Build.Cycle
  alias Kogen.Engine.Build.Escalation
  alias Kogen.Engine.Build.GateSupport
  alias Kogen.Engine.Build.Request
  alias Kogen.Engine.Build.Session
  alias Kogen.Engine.Runtime
  alias Kogen.Proc.Sandbox
  alias Kogen.Project
  alias Kogen.State.Approval
  alias Kogen.State.Run
  alias Kogen.Testkit.Git
  alias Kogen.Workspace

  test "escalation Candidate starts at the original base without Luna edits", %{
    tmp_dir: tmp_dir
  } do
    fixture = project_fixture!(tmp_dir)
    approval = approval(fixture.base_sha)
    run = run_record!(fixture)
    request = request(fixture, tmp_dir)
    luna_path = candidate!(fixture, run.id, approval)

    File.write!(
      Path.join(luna_path, "lib/tiny_app.ex"),
      "defmodule TinyApp do\n def value, do: :wrong\nend\n"
    )

    session = build_session!(fixture, tmp_dir, request, approval, run, luna_path)

    assert {:ok, escalated} = Escalation.reset_candidate(session)
    assert escalated.workdir != luna_path
    assert escalated.attempt == :escalation
    assert GateSupport.harness_options(escalated).limits == %{max_turns: 60, wall_ms: 1_800_000}
    assert {:ok, base_sha} = Workspace.rev_parse(escalated.workdir, "HEAD", escalated.git_env)
    assert base_sha == fixture.base_sha

    assert ":base\n" ==
             Kogen.Testkit.Proc.cmd!(
               "elixir",
               ["-r", "lib/tiny_app.ex", "-e", "IO.inspect(TinyApp.value())"],
               cd: escalated.workdir
             )

    refute File.exists?(luna_path)
  end

  defp project_fixture!(tmp_dir) do
    project = Git.create!(Path.join(tmp_dir, "project"))
    write_project!(project)
    Git.git!(project, ["add", "--all"])
    Git.git!(project, ["commit", "--quiet", "-m", "seed escalation fixture"])
    Git.git!(project, ["branch", "-M", "main"])

    origin = Git.bare!(Path.join(tmp_dir, "origin.git"))
    Git.git!(project, ["remote", "add", "origin", origin])
    Git.git!(project, ["push", "--quiet", "origin", "main"])
    {:ok, base_sha} = Workspace.ref_read(origin, "refs/heads/main", Git.env())

    %{
      project: project,
      origin: origin,
      base_sha: base_sha,
      git_env: Git.env(),
      workspace_root: Path.join([tmp_dir, ".kogen", "workspaces", "tiny-app"])
    }
  end

  defp write_project!(project) do
    write(
      project,
      ".kogen/project.yaml",
      "name: tiny_app\nchecks: []\nfix: []\ndomains:\n  kernel: [lib]\n"
    )

    write(
      project,
      "lib/tiny_app.ex",
      "defmodule TinyApp do\n  # revision: base\n  def value, do: :base\nend\n"
    )

    write(
      project,
      "mix.exs",
      ~s(defmodule TinyApp.MixProject do\n  use Mix.Project\n  def project, do: [app: :tiny_app, version: "0.1.0", elixir: "~> 1.20"]\nend\n)
    )

    write(project, ".kogen/intents/escalation/intent.md", intent_text())
    write(project, ".kogen/acceptance/escalation_test.exs", acceptance_source())
  end

  defp candidate!(fixture, run_id, approval) do
    assert {:ok, %{path: path}} =
             Workspace.create(
               fixture.origin,
               fixture.base_sha,
               fixture.workspace_root,
               run_id,
               fixture.git_env,
               seed_from: fixture.project
             )

    acceptance_path = ".kogen/acceptance/#{approval.slug}_test.exs"
    acceptance = Map.fetch!(approval.acceptance_files, acceptance_path)

    assert :ok =
             Workspace.insert_files(path, %{
               ".kogen/intents/#{approval.slug}/intent.md" => approval.intent_bytes,
               acceptance_path => acceptance,
               "test/acceptance/#{approval.slug}_test.exs" => acceptance
             })

    path
  end

  defp build_session!(fixture, tmp_dir, request, approval, run, workdir) do
    {:ok, %Kogen.Contracts.Project{} = project} = Project.load(workdir)

    runtime =
      request.runtime |> Runtime.trust_workspace(workdir) |> Runtime.for_run(run.dir)

    {:ok, env} = Kogen.Engine.candidate_environment(workdir, runtime, project)
    env = env |> Runtime.trust_workspace(workdir) |> Runtime.for_run(run.dir)

    {:ok, intent} =
      Kogen.Intent.parse_binary(approval.intent_bytes, ".kogen/intents/escalation/intent.md")

    sandbox = sandbox(tmp_dir, fixture, env, run.dir, workdir)

    %Session{
      request: request,
      approval: approval,
      approval_commit: "approval",
      intent: intent,
      intent_text: approval.intent_bytes,
      project: project,
      run: run,
      sandbox: sandbox,
      cycle: Cycle.new(%{approval: approval, repairs: 2, recipe: request.recipe}),
      state_root: fixture.workspace_root,
      run_dir: run.dir,
      base_sha: fixture.base_sha,
      workdir: workdir,
      process_env: env,
      git_env: Runtime.git_environment(env),
      attempt: :builder,
      receipts: [],
      acceptance: []
    }
  end

  defp sandbox(tmp_dir, fixture, env, run_dir, workdir) do
    %Sandbox{
      enabled: false,
      home: tmp_dir,
      project_root: fixture.project,
      origin: fixture.origin,
      workspace: workdir,
      run_dir: run_dir,
      tmp_dir: Runtime.temporary_directory(env)
    }
  end

  defp request(fixture, tmp_dir) do
    mise = Path.join(tmp_dir, "mise")
    File.write!(mise, ~s(#!/bin/sh\nprintf '%s\\n' '{"MIX_ENV":"test"}'\n))
    File.chmod!(mise, 0o755)

    runtime = %Runtime{
      base_env: %{"HOME" => tmp_dir, "PATH" => "/usr/bin:/bin"},
      git_env: fixture.git_env,
      mise: mise
    }

    %Request{
      slug: "escalation",
      home: tmp_dir,
      project_root: fixture.project,
      workspace_root: fixture.workspace_root,
      origin: fixture.origin,
      base: "main",
      model: "gpt-6-luna",
      effort: "max",
      recipe: Kogen.Engine.build_recipe("escalate-shell", "gpt-6-luna", "max"),
      runtime: runtime,
      provider_mod: Kogen.Provider.Fake,
      provider_config: nil,
      credential_source: :custom,
      credential_label: "test"
    }
  end

  defp approval(base_sha) do
    %Approval{
      slug: "escalation",
      intent_bytes: intent_text(),
      intent_sha256: Kogen.Intent.hash(intent_text()),
      target_branch: "main",
      base_sha: base_sha,
      domains: ["kernel"],
      acceptance_files: %{".kogen/acceptance/escalation_test.exs" => acceptance_source()},
      protected_manifest: %{},
      by: "test",
      at: ~U[2026-10-04 00:00:00Z]
    }
  end

  defp run_record!(fixture) do
    run_dir = Path.join([fixture.workspace_root, "runs", "fresh-run"])
    File.mkdir_p!(run_dir)

    %Run{
      id: "fresh-run",
      dir: run_dir,
      slug: "escalation",
      intent_sha256: Kogen.Intent.hash(intent_text()),
      target_branch: "main",
      approval_commit: "approval",
      status: :running,
      landing: nil
    }
  end

  defp write(project, relative, contents) do
    path = Path.join(project, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp intent_text do
    """
    ---
    title: "Fresh escalation"
    domains: [kernel]
    size: small
    ---
    Keep the approved TinyApp intent in the new Candidate.

    ## Acceptance
    - A1: TinyApp.value/0 returns :ready.

    ## Verify
    - A1: test
    """
  end

  defp acceptance_source do
    """
    defmodule TinyApp.AcceptanceTest do
      use ExUnit.Case, async: true
      @tag intent: "escalation/A1"
      test "returns ready" do
        assert TinyApp.value() == :ready
      end
    end
    """
  end
end
