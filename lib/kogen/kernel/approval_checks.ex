defmodule Kogen.Kernel.ApprovalChecks do
  @moduledoc false

  alias Kogen.Checks
  alias Kogen.Checks.Timing
  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.CommandExit
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project, as: ProjectData
  alias Kogen.Engine.Build.Setup
  alias Kogen.Engine.Runtime
  alias Kogen.Kernel.Approval.Request
  alias Kogen.Kernel.Workspaces
  alias Kogen.Proc
  alias Kogen.Proc.Sandbox
  alias Kogen.Project
  alias Kogen.Workspace

  @spec run(Request.t(), ProjectData.t(), String.t(), %{String.t() => binary()}) ::
          {:ok, [map()]} | {:error, term()}
  def run(%Request{} = request, %ProjectData{} = project, base_sha, acceptance_files) do
    env = Map.merge(request.env, project.env)
    run_dir = approval_run_dir(env, request.slug)
    sandbox = approval_sandbox(request, project, run_dir, env)
    git_env = Runtime.git_environment(env)
    root = request.project_root

    with {:ok, base_tree} <- base_tree_sha(request.origin, base_sha, git_env),
         {:ok, setup_result} <-
           Project.run_setup(
             project,
             root,
             setup_cache_root(root, request.home),
             base_tree,
             env,
             fn -> Setup.run(project.setup, root, run_dir, env, Proc, sandbox) end
           ),
         :ok <- Project.record_setup_reuse(run_dir, setup_result),
         {:ok, check_result} <-
           Checks.run_all(root, project, run_dir, env, git_env, %{
             sandbox: sandbox,
             baseline_run?: true
           }),
         :ok <- acceptance_checks(request, project, acceptance_files, env, sandbox, run_dir) do
      Timing.complete(run_dir)
      {:ok, CheckBaseline.from_assessments(check_result.checks)}
    end
  end

  defp acceptance_checks(
         _request,
         %ProjectData{acceptance_checks: []},
         _files,
         _env,
         _sandbox,
         _run_dir
       ), do: :ok

  defp acceptance_checks(request, project, files, env, sandbox, run_dir) do
    relative = "test/acceptance/#{request.slug}_test.exs"
    bytes = Map.fetch!(files, ".kogen/acceptance/#{request.slug}_test.exs")
    path = Path.join(request.project_root, relative)

    with {:ok, created?} <- stage_candidate(path, relative, bytes) do
      result =
        run_acceptance_checks(
          project.acceptance_checks,
          request.project_root,
          relative,
          env,
          sandbox,
          run_dir
        )

      if created?, do: cleanup_candidate(path, relative, result), else: result
    end
  end

  defp stage_candidate(path, relative, bytes) do
    case File.read(path) do
      {:ok, ^bytes} -> {:ok, false}
      {:ok, _existing} -> {:error, {:acceptance_check_path_conflict, relative}}
      {:error, :enoent} -> create_candidate(path, relative, bytes)
      {:error, reason} -> {:error, {:acceptance_check_path_unavailable, relative, reason}}
    end
  end

  defp create_candidate(path, relative, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes, [:binary, :exclusive]) do
      {:ok, true}
    else
      {:error, :eexist} -> stage_candidate(path, relative, bytes)
      {:error, reason} -> {:error, {:acceptance_check_path_unavailable, relative, reason}}
    end
  end

  defp run_acceptance_checks(specs, root, relative, env, _sandbox, run_dir) do
    Enum.reduce_while(specs, :ok, fn spec, :ok ->
      argv = Enum.map(spec.argv, &if(&1 == "{path}", do: relative, else: &1))

      case argv
           |> Proc.run(cd: root, env: env, timeout_ms: spec.timeout_ms)
           |> Timing.process(
             run_dir,
             spec.name,
             argv
           ) do
        {:ok, %ProcResult{exit_status: 0, timed_out: false}} ->
          {:cont, :ok}

        {:ok, %ProcResult{} = result} ->
          if CommandExit.tool_missing?(result.exit_status) do
            {:halt,
             {:error,
              %Failure{
                class: :environment,
                reason: :tool_missing,
                detail:
                  "Acceptance check #{spec.name} could not run (exit status #{result.exit_status}); a required tool is unavailable."
              }}}
          else
            {:halt, {:error, {:acceptance_check_failed, spec.name, {:ok, result}}}}
          end

        result ->
          {:halt, {:error, {:acceptance_check_failed, spec.name, result}}}
      end
    end)
  end

  defp cleanup_candidate(path, relative, result) do
    case File.rm(path) do
      :ok -> result
      {:error, :enoent} -> result
      {:error, reason} -> {:error, {:acceptance_check_cleanup_failed, relative, reason}}
    end
  end

  defp approval_sandbox(%Request{runtime: nil}, _project, _run_dir, _env), do: nil

  defp approval_sandbox(request, project, run_dir, env) do
    %Sandbox{
      enabled:
        project.sandbox and not Runtime.sandboxed?(env) and
          not Runtime.sandboxed?(request.runtime),
      home: request.home,
      project_root: request.project_root,
      origin: request.origin,
      workspace: request.project_root,
      run_dir: run_dir,
      tmp_dir: Runtime.temporary_directory(env),
      workspace_is_project: true
    }
  end

  defp approval_run_dir(env, slug) do
    id = "#{System.monotonic_time(:microsecond)}-#{System.unique_integer([:positive])}"
    Path.join([Runtime.temporary_directory(env), "kogen-approval", slug, id])
  end

  defp setup_cache_root(_root, nil), do: nil

  defp setup_cache_root(root, home), do: Path.join(Workspaces.root(root, home), "setup-cache")

  defp base_tree_sha(origin, base_sha, git_env),
    do: Workspace.rev_parse(origin, "#{base_sha}^{tree}", git_env)
end
