defmodule Kogen.Checks.FinalPass do
  @moduledoc false

  alias Kogen.Checks.Feedback
  alias Kogen.Checks.FinalPass.Cache
  alias Kogen.Checks.ReceiptBuilder
  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.CheckOutput
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc

  def run(workdir, project, run_dir, env, sandbox, baseline) do
    Cache.once(workdir, run_dir, env, project.fix, baseline, fn directory ->
      with :ok <- File.mkdir_p(Path.join(directory, "logs")) do
        results =
          project.fix
          |> Enum.with_index(1)
          |> Enum.map(fn {spec, index} ->
            execute(workdir, directory, env, sandbox, baseline, {spec, index})
          end)

        {:ok, results}
      end
    end)
  end

  def receipts(tree, project, results) do
    project.fix
    |> Enum.zip(results)
    |> Enum.reduce_while({:ok, []}, fn {spec, result}, {:ok, receipts} ->
      spec = %{spec | name: "fix/#{spec.name}"}

      case ReceiptBuilder.build(tree, spec, result.exit_status || 1, result.log_path, result) do
        {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, receipts} -> {:ok, Enum.reverse(receipts)}
      error -> error
    end
  end

  def passed(results) do
    red = Enum.reject(results, &(&1.exit_level == 0 or &1.base_red?))

    if red == [],
      do: :ok,
      else:
        {:error,
         %Failure{
           class: :candidate,
           reason: :fix_failed,
           detail: Feedback.render_model_feedback(red)
         }}
  end

  defp execute(workdir, directory, env, sandbox, baseline, {spec, index}) do
    log = Path.join([directory, "logs", "fix-#{index}.log"])

    options = [
      cd: workdir,
      env: env,
      sandbox: sandbox,
      timeout_ms: spec.timeout_ms,
      log_path: log
    ]

    result = process_result(Proc.run(spec.argv, options), spec, log)
    spec = %{spec | name: "fix/#{spec.name}"}

    %CheckOutput{
      name: spec.name,
      argv: spec.argv,
      exit_status: result.exit_status,
      timed_out: result.timed_out,
      output: result.output_tail,
      log_path: log,
      workdir: workdir
    }
    |> Feedback.analyze()
    |> Feedback.gate(spec, [])
    |> CheckBaseline.annotate(baseline)
  end

  defp process_result({:ok, result}, _spec, _log), do: result

  defp process_result({:error, reason}, spec, log) do
    output = "Command was not found or could not run: #{inspect(reason)}"
    File.write!(log, output)

    %ProcResult{
      argv: spec.argv,
      exit_status: nil,
      timed_out: false,
      output_tail: output,
      log_path: log,
      duration_ms: 0
    }
  end
end
