defmodule Kogen.Checks.Fixer.State do
  @moduledoc false

  @enforce_keys [:workdir, :run_dir, :env, :sandbox]
  defstruct [:workdir, :run_dir, :env, :sandbox, baseline: [], index: 1, results: []]

  @type t :: %__MODULE__{
          workdir: Path.t(),
          run_dir: Path.t(),
          env: %{String.t() => String.t()},
          sandbox: Kogen.Proc.Sandbox.t() | nil,
          baseline: [map()],
          index: pos_integer(),
          results: [Kogen.Contracts.ProcResult.t()]
        }
end

defmodule Kogen.Checks.Fixer do
  @moduledoc false

  alias Kogen.Checks.Feedback
  alias Kogen.Checks.Fixer.State
  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.CheckOutput
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
  def run(workdir, project, run_dir, env, sandbox),
    do: run(workdir, project, run_dir, env, sandbox, [])

  def run(workdir, %Project{} = project, run_dir, env, sandbox, baseline) do
    with :ok <- prepare_logs(run_dir) do
      run_specs(project.fix, %State{
        workdir: workdir,
        run_dir: run_dir,
        env: env,
        baseline: baseline,
        sandbox: sandbox
      })
    end
  end

  defp run_specs([], %State{results: results}), do: {:ok, Enum.reverse(results)}

  defp run_specs([spec | rest], %State{} = state) do
    log_path =
      Path.join([state.run_dir, "logs", "fix-#{state.index}-#{safe_name(spec.name)}.log"])

    result =
      Proc.run(spec.argv,
        cd: state.workdir,
        env: state.env,
        timeout_ms: spec.timeout_ms,
        log_path: log_path,
        sandbox: state.sandbox
      )

    case assess(result, %{spec | name: "fix/#{spec.name}"}, log_path, state) do
      {:ok, process} ->
        run_specs(rest, %{state | index: state.index + 1, results: [process | state.results]})

      {:error, failure} ->
        {:error, failure}
    end
  end

  defp assess({:error, reason}, spec, log_path, state) do
    result = %ProcResult{
      argv: spec.argv,
      exit_status: nil,
      timed_out: false,
      output_tail: "Command was not found or could not run: #{inspect(reason)}",
      log_path: log_path,
      duration_ms: 0
    }

    assess({:ok, result}, spec, log_path, state)
  end

  defp assess({:ok, result}, spec, log_path, state) do
    assessment =
      %CheckOutput{
        name: spec.name,
        argv: spec.argv,
        exit_status: result.exit_status,
        timed_out: result.timed_out,
        output: result.output_tail,
        log_path: log_path,
        workdir: state.workdir
      }
      |> Feedback.analyze()
      |> Feedback.gate(spec, [])
      |> CheckBaseline.annotate(state.baseline)

    if assessment.exit_level == 0 or assessment.base_red?,
      do: {:ok, result},
      else:
        {:error, failure(:candidate, :fix_failed, Feedback.render_model_feedback([assessment]))}
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
