defmodule Kogen.Engine.Build.Setup do
  @moduledoc false

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.CommandExit
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Engine.Build.Lifecycle
  alias Kogen.Engine.Build.Session
  alias Kogen.Proc.Sandbox
  alias Kogen.Project, as: ProjectDomain
  alias Kogen.Workspace

  @spec run([CheckSpec.t()], Path.t(), Path.t(), %{String.t() => String.t()}, module()) ::
          :ok | {:error, Failure.t()}
  def run([], _workdir, _run_dir, _env, _proc_mod), do: :ok

  def run(specs, workdir, run_dir, env, proc_mod),
    do: run(specs, workdir, run_dir, env, proc_mod, nil)

  @spec run(
          [CheckSpec.t()],
          Path.t(),
          Path.t(),
          %{String.t() => String.t()},
          module(),
          Sandbox.t() | nil
        ) :: :ok | {:error, Failure.t()}
  def run([], _workdir, _run_dir, _env, _proc_mod, _sandbox), do: :ok

  def run(specs, workdir, run_dir, env, proc_mod, sandbox) do
    case File.mkdir_p(Path.join(run_dir, "logs")) do
      :ok ->
        run_specs(specs, workdir, run_dir, env, proc_mod, sandbox)

      {:error, reason} ->
        {:error, failure(:setup_failed, "cannot prepare setup logs: #{inspect(reason)}")}
    end
  end

  @spec run_cached(Session.t()) :: :ok | {:error, term()}
  def run_cached(%Session{project: %{setup: []}}), do: :ok

  def run_cached(%Session{} = session) do
    cache_root = Path.join(session.request.workspace_root, "setup-cache")

    with {:ok, base_tree_sha} <-
           Workspace.rev_parse(session.workdir, "HEAD^{tree}", session.git_env),
         {:ok, setup_result} <-
           ProjectDomain.run_setup(
             session.project,
             session.workdir,
             cache_root,
             base_tree_sha,
             session.process_env,
             fn ->
               run(
                 session.project.setup,
                 session.workdir,
                 session.run_dir,
                 session.process_env,
                 Kogen.Proc,
                 session.sandbox
               )
             end
           ) do
      Lifecycle.record_setup_reuse(session.run, setup_result)
    end
  end

  defp run_specs([], _workdir, _run_dir, _env, _proc_mod, _sandbox), do: :ok

  defp run_specs([%CheckSpec{} = spec | rest], workdir, run_dir, env, proc_mod, sandbox) do
    log_path = Path.join([run_dir, "logs", "setup-#{safe_name(spec.name)}.log"])

    result =
      proc_mod.run(spec.argv,
        cd: workdir,
        env: env,
        timeout_ms: spec.timeout_ms,
        log_path: log_path,
        sandbox: sandbox
      )

    case result do
      {:ok, %ProcResult{exit_status: 0, timed_out: false}} ->
        run_specs(rest, workdir, run_dir, env, proc_mod, sandbox)

      {:ok, %ProcResult{} = proc_result} ->
        {:error, command_failure(spec.name, proc_result)}

      {:error, reason} ->
        {:error, failure(:setup_failed, "setup command #{spec.name} failed: #{inspect(reason)}")}
    end
  end

  defp command_failure(name, %ProcResult{} = result) do
    status =
      if result.timed_out, do: "timed out", else: "exit status #{inspect(result.exit_status)}"

    output = output_tail(result.output_tail)
    detail = "setup command #{name} failed (#{status})"
    detail = if output == "", do: detail, else: detail <> "\n" <> output

    reason =
      if CommandExit.tool_missing?(result.exit_status), do: :tool_missing, else: :setup_failed

    failure(reason, detail)
  end

  defp output_tail(output) when byte_size(output) <= 2_048, do: String.replace_invalid(output)

  defp output_tail(output) do
    offset = byte_size(output) - 2_048
    output |> binary_part(offset, 2_048) |> String.replace_invalid()
  end

  defp safe_name(name), do: Regex.replace(~r/[^A-Za-z0-9_.-]/, name, "_")

  defp failure(reason, detail), do: %Failure{class: :environment, reason: reason, detail: detail}
end
