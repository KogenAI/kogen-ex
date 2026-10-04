defmodule Kogen.Checks.Fixer.State do
  @moduledoc false

  @enforce_keys [:workdir, :run_dir, :env, :sandbox]
  defstruct [:workdir, :run_dir, :env, :sandbox, index: 1, results: []]

  @type t :: %__MODULE__{
          workdir: Path.t(),
          run_dir: Path.t(),
          env: %{String.t() => String.t()},
          sandbox: Kogen.Proc.Sandbox.t() | nil,
          index: pos_integer(),
          results: [Kogen.Contracts.ProcResult.t()]
        }
end

defmodule Kogen.Checks.Fixer do
  @moduledoc false

  alias Kogen.Checks.Fixer.State
  alias Kogen.Contracts.CommandExit
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project
  alias Kogen.Proc

  @spec run(Path.t(), Project.t(), Path.t()) :: {:ok, [ProcResult.t()]} | {:error, Failure.t()}
  def run(workdir, project, run_dir), do: run(workdir, project, run_dir, %{})

  @spec run(Path.t(), Project.t(), Path.t(), %{String.t() => String.t()}) ::
          {:ok, [ProcResult.t()]} | {:error, Failure.t()}
  def run(workdir, project, run_dir, env), do: run(workdir, project, run_dir, env, nil)

  @spec run(
          Path.t(),
          Project.t(),
          Path.t(),
          %{String.t() => String.t()},
          Kogen.Proc.Sandbox.t() | nil
        ) :: {:ok, [ProcResult.t()]} | {:error, Failure.t()}
  def run(workdir, %Project{} = project, run_dir, env, sandbox) do
    with :ok <- prepare_logs(run_dir) do
      run_specs(project.fix, %State{
        workdir: workdir,
        run_dir: run_dir,
        env: env,
        sandbox: sandbox
      })
    end
  end

  defp run_specs([], %State{results: results}), do: {:ok, Enum.reverse(results)}

  defp run_specs([spec | rest], %State{} = state) do
    log_path =
      Path.join([state.run_dir, "logs", "fix-#{state.index}-#{safe_name(spec.name)}.log"])

    case Proc.run(spec.argv,
           cd: state.workdir,
           env: state.env,
           timeout_ms: spec.timeout_ms,
           log_path: log_path,
           sandbox: state.sandbox
         ) do
      {:ok, %ProcResult{exit_status: 0, timed_out: false} = result} ->
        run_specs(rest, %{state | index: state.index + 1, results: [result | state.results]})

      {:ok, %ProcResult{timed_out: true}} ->
        {:error, failure(:candidate, :fix_timeout, "safe formatter timed out: #{spec.name}")}

      {:ok, %ProcResult{exit_status: status}} ->
        if CommandExit.tool_missing?(status) do
          {:error,
           failure(:environment, :tool_missing, "safe formatter tool missing: #{spec.name}")}
        else
          {:error,
           failure(
             :candidate,
             :fix_failed,
             "safe formatter #{spec.name} exited #{inspect(status)}"
           )}
        end

      {:error, :enoent} ->
        {:error,
         failure(:environment, :tool_missing, "safe formatter tool missing: #{spec.name}")}

      {:error, reason} ->
        {:error,
         failure(:environment, :process_failed, "safe formatter #{spec.name}: #{inspect(reason)}")}
    end
  end

  defp prepare_logs(run_dir) do
    if Path.type(run_dir) == :absolute do
      case File.mkdir_p(Path.join(run_dir, "logs")) do
        :ok -> :ok
        {:error, reason} -> {:error, failure(:environment, :log_directory, inspect(reason))}
      end
    else
      {:error, failure(:controller, :invalid_run_dir, "run directory must be absolute")}
    end
  end

  defp safe_name(name), do: Regex.replace(~r/[^A-Za-z0-9_.-]/, name, "_")
  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
