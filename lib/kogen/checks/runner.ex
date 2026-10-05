defmodule Kogen.Checks.Runner do
  @moduledoc false

  alias Kogen.Checks.Feedback
  alias Kogen.Checks.ReceiptBuilder
  alias Kogen.Checks.RunState
  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.Receipt
  alias Kogen.Proc
  alias Kogen.Proc.Sandbox
  alias Kogen.Workspace

  @spec run_all(
          Path.t(),
          Project.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()}
        ) ::
          {:ok,
           %{
             tree: String.t(),
             receipts: [Receipt.t()],
             status: :pass | {:fail, [String.t()]},
             feedback: String.t(),
             exit_levels: [{String.t(), 0..3}],
             checks: [map()],
             warnings: [String.t()]
           }}
          | {:error, Failure.t()}
  def run_all(workdir, project, run_dir, env, git_env),
    do: run_all(workdir, project, run_dir, env, git_env, nil)

  @spec run_all(
          Path.t(),
          Project.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()},
          Sandbox.t() | map() | nil
        ) ::
          {:ok,
           %{
             tree: String.t(),
             receipts: [Receipt.t()],
             status: :pass | {:fail, [String.t()]},
             feedback: String.t(),
             exit_levels: [{String.t(), 0..3}],
             checks: [map()],
             warnings: [String.t()]
           }}
          | {:error, Failure.t()}
  def run_all(workdir, %Project{} = project, run_dir, env, git_env, options) do
    workdir
    |> run_all_with_project(project, run_dir, env, git_env, options(options))
    |> Kogen.Quality.augment(workdir, run_dir, Map.merge(env, git_env), options)
  end

  defp run_all_with_project(workdir, %Project{} = project, run_dir, env, git_env, options) do
    with :ok <- prepare_logs(run_dir),
         {:ok, before_tree} <- Workspace.tree_hash(workdir, git_env) do
      state = %RunState{
        workdir: workdir,
        run_dir: run_dir,
        env: env,
        tree: before_tree,
        git_env: git_env,
        baseline: options.check_baseline,
        sandbox: options.sandbox,
        baseline_run?: options.baseline_run?
      }

      finish_run(
        run_specs(specs(project, options), state),
        before_tree,
        workdir,
        git_env,
        options.check_baseline
      )
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      {:error, reason} -> {:error, failure(:controller, :workspace_failed, inspect(reason))}
    end
  end

  defp finish_run(results, before_tree, workdir, git_env, baseline) do
    with {:ok, _after_tree} <- Workspace.tree_hash(workdir, git_env),
         {:ok, receipts, failures, feedbacks} <- results do
      checks = Enum.map(feedbacks, &CheckBaseline.annotate(&1, baseline))
      base_red = Enum.filter(checks, & &1.base_red?)
      active_checks = Enum.reject(checks, & &1.base_red?)
      failures = Enum.reject(failures, &base_red_name?(base_red, &1))
      receipts = Enum.reject(receipts, &base_red_name?(base_red, &1.check))
      status = if failures == [], do: :pass, else: {:fail, failures}
      feedback = if failures == [], do: "", else: Feedback.render_model_feedback(active_checks)
      exit_levels = Enum.map(checks, &{&1.name, &1.exit_level})
      warnings = Enum.flat_map(checks, &CheckBaseline.warning/1)

      {:ok,
       %{
         tree: before_tree,
         receipts: receipts,
         status: status,
         feedback: feedback,
         exit_levels: exit_levels,
         checks: checks,
         warnings: warnings
       }}
    end
  end

  defp base_red_name?(checks, name), do: Enum.any?(checks, &(&1.name == name))

  defp options(%Sandbox{} = sandbox),
    do: %{sandbox: sandbox, check_baseline: [], baseline_run?: false}

  defp options(nil), do: %{sandbox: nil, check_baseline: [], baseline_run?: false}

  defp options(options) when is_map(options),
    do: Map.merge(%{sandbox: nil, check_baseline: [], baseline_run?: false}, options)

  defp run_specs(specs, %RunState{} = initial) do
    case Enum.reduce_while(specs, {:ok, initial}, &reduce_spec/2) do
      {:ok, %RunState{} = state} ->
        {:ok, Enum.reverse(state.receipts), Enum.reverse(state.failures),
         Enum.reverse(state.feedbacks)}

      error ->
        error
    end
  end

  defp reduce_spec(%CheckSpec{} = spec, {:ok, %RunState{} = state}) do
    case run_spec(spec, state) do
      {:ok, next_state} -> {:cont, {:ok, next_state}}
      {:error, failure} -> {:halt, {:error, failure}}
    end
  end

  defp specs(project, %{baseline_run?: true}) do
    Enum.map(project.fix, &%{&1 | name: "fix/#{&1.name}"}) ++ project.checks
  end

  defp specs(project, _options), do: project.checks

  defp run_spec(%CheckSpec{} = spec, %RunState{} = state) do
    log_path = check_log(state.run_dir, state.index, spec.name)

    options = [
      cd: state.workdir,
      env: state.env,
      timeout_ms: spec.timeout_ms,
      log_path: log_path,
      sandbox: state.sandbox
    ]

    run = fn ->
      result = process_result(Proc.run(spec.argv, options), spec, log_path)
      {analyze_result(spec, result, log_path, state.workdir), result}
    end

    with {:ok, {assessment, result}} <-
           Kogen.Checks.Verification.verify_command(
             state.workdir,
             state.git_env,
             spec,
             if(state.baseline_run?, do: :record, else: state.baseline),
             run
           ),
         {:ok, receipt} <-
           ReceiptBuilder.build(state.tree, spec, result.exit_status || 1, log_path) do
      record_result(state, spec, assessment, receipt)
    else
      {:error, reason} -> {:error, failure(:controller, :check_record_failed, inspect(reason))}
    end
  end

  defp process_result({:ok, result}, _spec, _log_path), do: result

  defp process_result({:error, reason}, spec, log_path) do
    output =
      if reason == :enoent,
        do: "Command was not found on the explicit PATH.",
        else: "Process could not run: #{inspect(reason)}"

    File.write!(log_path, output)

    %ProcResult{
      argv: spec.argv,
      exit_status: nil,
      timed_out: false,
      output_tail: output,
      log_path: log_path,
      duration_ms: 0
    }
  end

  defp record_result(state, spec, assessment, receipt) do
    failures =
      if assessment.exit_level == 0, do: state.failures, else: [spec.name | state.failures]

    {:ok,
     %{
       state
       | index: state.index + 1,
         receipts: [receipt | state.receipts],
         failures: failures,
         feedbacks: [assessment | state.feedbacks]
     }}
  end

  defp analyze_result(spec, result, log_path, workdir) do
    Feedback.analyze(%{
      name: spec.name,
      argv: spec.argv,
      exit_status: result.exit_status,
      timed_out: result.timed_out,
      output: result.output_tail,
      log_path: log_path,
      workdir: workdir
    })
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

  defp check_log(run_dir, index, name) do
    safe_name = Regex.replace(~r/[^A-Za-z0-9_.-]/, name, "_")
    Path.join([run_dir, "logs", "check-#{index}-#{safe_name}.log"])
  end

  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
