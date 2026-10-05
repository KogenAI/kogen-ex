defmodule Kogen.Checks.Runner do
  @moduledoc false

  alias Kogen.Checks.Feedback
  alias Kogen.Checks.ReceiptBuilder
  alias Kogen.Checks.RunState
  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.CommandExit
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
    run_all_with_project(workdir, project, run_dir, env, git_env, options(options))
  end

  defp run_all_with_project(workdir, %Project{} = project, run_dir, env, git_env, options) do
    with :ok <- prepare_logs(run_dir),
         {:ok, before_tree} <- Workspace.tree_hash(workdir, git_env) do
      state = %RunState{
        workdir: workdir,
        run_dir: run_dir,
        env: env,
        tree: before_tree,
        sandbox: options.sandbox,
        baseline_run?: options.baseline_run?
      }

      finish_run(
        run_specs(project.checks, state),
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
    with {:ok, after_tree} <- Workspace.tree_hash(workdir, git_env),
         :ok <- same_tree(before_tree, after_tree),
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

  defp run_spec(%CheckSpec{} = spec, %RunState{} = state) do
    log_path = check_log(state.run_dir, state.index, spec.name)
    options = [cd: state.workdir, env: state.env, timeout_ms: spec.timeout_ms, log_path: log_path]
    options = Keyword.put(options, :sandbox, state.sandbox)
    update_from_process(Proc.run(spec.argv, options), spec, log_path, state)
  end

  defp update_from_process({:ok, %ProcResult{timed_out: true} = result}, spec, log_path, state) do
    assessment = analyze_result(spec, result, log_path, state.workdir)

    {:error,
     failure(
       :environment,
       :check_unavailable,
       Feedback.render_environment_detail(prior_assessments(state, assessment))
     )}
  end

  defp update_from_process(
         {:ok, %ProcResult{exit_status: status} = result},
         spec,
         log_path,
         state
       )
       when is_integer(status) do
    assessment = analyze_result(spec, result, log_path, state.workdir)

    if assessment.exit_level == 3 and not state.baseline_run? do
      reason =
        if CommandExit.tool_missing?(result.exit_status),
          do: :tool_missing,
          else: :check_unavailable

      {:error,
       failure(
         :environment,
         reason,
         Feedback.render_environment_detail(prior_assessments(state, assessment))
       )}
    else
      case ReceiptBuilder.build(state.tree, spec, status, log_path) do
        {:ok, receipt} ->
          record_result(state, spec, assessment, receipt)

        {:error, reason} ->
          {:error, failure(:environment, reason, "check log unavailable for #{spec.name}")}
      end
    end
  end

  defp update_from_process({:ok, %ProcResult{exit_status: nil}}, spec, _log, _state) do
    {:error,
     failure(:environment, :missing_exit_status, "check #{spec.name} returned no exit status")}
  end

  defp update_from_process({:error, :enoent}, spec, _log, _state) do
    {:error, failure(:environment, :tool_missing, "check tool missing for #{spec.name}")}
  end

  defp update_from_process({:error, reason}, spec, _log, _state) do
    {:error, failure(:environment, :process_failed, "check #{spec.name}: #{inspect(reason)}")}
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

  defp prior_assessments(state, assessment), do: Enum.reverse([assessment | state.feedbacks])

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

  defp same_tree(tree, tree), do: :ok

  defp same_tree(_before, _after),
    do: {:error, failure(:candidate, :tree_mutated, "a check changed the candidate tree")}

  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
