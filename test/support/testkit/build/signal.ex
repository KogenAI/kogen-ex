defmodule Kogen.E2e.Build.Signal do
  @moduledoc false

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Environment
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Proc
  alias Kogen.State
  alias Kogen.Workspace

  def run(parent, seed_project, pid_path) do
    command = "printf '%s\\n' \"$$\" > lib/kogen-term-child.pid; exec sleep 60"

    steps = [
      ScriptedProvider.answer(:context, "Inspect the tiny project."),
      ScriptedProvider.answer(:plan, "Run the requested check."),
      ScriptedProvider.call(:develop, "shell", %{"cmd" => command})
    ]

    {:ok, server} = ScriptedProvider.start_link(steps)
    {fixture, request} = Build.prepare!(parent, seed_project, server)
    File.write!(pid_path, System.pid())

    Kogen.Kernel.CLI.main(
      ["queue", "start", "--project", fixture.project_root, "--origin", fixture.origin],
      fn _argv -> execute(request) end
    )
  end

  def workspace_root(project_root, home), do: Build.workspace_root(project_root, home)

  def process_alive?(pid) do
    case Proc.run([kill_path(), "-0", pid], cd: "/tmp", timeout_ms: 5_000) do
      {:ok, %{exit_status: 0}} -> true
      _other -> false
    end
  end

  def signal_process(pid, signal) do
    case Proc.run([kill_path(), "-#{signal}", pid], cd: "/tmp", timeout_ms: 5_000) do
      {:ok, %{exit_status: 0}} -> :ok
      {:ok, %{exit_status: status, output_tail: output}} -> {:error, {status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  def run_child(argv, options), do: Proc.run(argv, options)

  def reconcile_run(project, workspace_root, origin, home, git_env) do
    with {:ok, [run]} <- State.list(workspace_root),
         events = File.read!(Path.join(run.dir, "events.jsonl")),
         interrupted = String.contains?(events, ~s("event":"interrupted")),
         {:ok, :crashed} <- reconcile_with_kernel(run.id, project, origin, home),
         {:ok, reconciled} <- State.load(workspace_root, run.id),
         {:error, :missing} <- Workspace.ref_read(origin, "refs/kogen/claim", git_env) do
      {:ok,
       %{
         run_status: run.status,
         interrupted: interrupted,
         reconciliation: :crashed,
         reconciled_status: reconciled.status,
         claim_released: true
       }}
    else
      other -> {:error, other}
    end
  end

  defp kill_path, do: System.find_executable("kill") || "/bin/kill"

  defp reconcile_with_kernel(run_id, project, origin, home) do
    env = Environment.child_env!(home)

    script =
      "IO.write(inspect(Kogen.Kernel.reconcile(#{inspect(run_id)}, #{inspect(project)}, #{inspect(origin)}, \"main\")))"

    elixir = Environment.executable!(env, "elixir")

    case Proc.run([elixir | child_args() ++ ["-e", script]],
           cd: project,
           env: env,
           timeout_ms: 30_000
         ) do
      {:ok, %{exit_status: 0, output_tail: output}} ->
        if String.trim(output) == "{:ok, :crashed}", do: {:ok, :crashed}, else: {:error, output}

      {:ok, result} ->
        {:error, {:reconcile_failed, result.exit_status, result.output_tail}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp child_args do
    Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
  end

  defp execute(request) do
    case Kogen.Kernel.build(request) do
      {:ok, result} ->
        log_path = Path.join([result.run_dir, "logs", "acceptance.log"])
        log = if File.regular?(log_path), do: File.read!(log_path), else: ""

        {if(result.status == :landed, do: 0, else: 1),
         inspect({result.status, result.failure, log})}

      {:error, reason} ->
        {2, "build failed: #{inspect(reason)}\n"}
    end
  end
end
