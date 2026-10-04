defmodule Kogen.Checks.Runner do
  @moduledoc false

  alias Kogen.Checks.Feedback
  alias Kogen.Checks.ReceiptBuilder
  alias Kogen.Checks.RunState
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.Receipt
  alias Kogen.Proc
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
             exit_levels: [{String.t(), 0..3}]
           }}
          | {:error, Failure.t()}
  def run_all(workdir, project, run_dir, env, git_env),
    do: run_all(workdir, project, run_dir, env, git_env, nil)

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
             exit_levels: [{String.t(), 0..3}]
           }}
          | {:error, Failure.t()}
  @spec run_all(
          Path.t(),
          Project.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()},
          Kogen.Proc.Sandbox.t() | nil
        ) ::
          {:ok,
           %{
             tree: String.t(),
             receipts: [Receipt.t()],
             status: :pass | {:fail, [String.t()]},
             feedback: String.t(),
             exit_levels: [{String.t(), 0..3}]
           }}
          | {:error, Failure.t()}
  def run_all(workdir, %Project{} = project, run_dir, env, git_env, sandbox),
    do: run_all_with_project(workdir, project, run_dir, env, git_env, sandbox)

  defp run_all_with_project(workdir, %Project{} = project, run_dir, env, git_env, sandbox) do
    with :ok <- prepare_logs(run_dir),
         {:ok, before_tree} <- Workspace.tree_hash(workdir, git_env) do
      state = %RunState{
        workdir: workdir,
        run_dir: run_dir,
        env: env,
        tree: before_tree,
        sandbox: sandbox
      }

      results = run_specs(project.checks, state)

      with {:ok, after_tree} <- Workspace.tree_hash(workdir, git_env),
           :ok <- same_tree(before_tree, after_tree),
           {:ok, receipts, failures, feedbacks} <- results do
        status = if failures == [], do: :pass, else: {:fail, failures}

        feedback =
          if failures == [], do: "", else: Feedback.render_model_feedback(feedbacks)

        exit_levels = Enum.map(feedbacks, &{&1.name, &1.exit_level})

        {:ok,
         %{
           tree: before_tree,
           receipts: receipts,
           status: status,
           feedback: feedback,
           exit_levels: exit_levels
         }}
      end
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      {:error, reason} -> {:error, failure(:controller, :workspace_failed, inspect(reason))}
    end
  end

  @spec protected_violations(
          Path.t(),
          String.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()}
        ) :: {:ok, [String.t()]} | {:error, term()}
  def protected_violations(workdir, base_sha, manifest, git_env) do
    with {:ok, _changed} <- Workspace.changed_paths(workdir, base_sha, git_env) do
      mismatches =
        Enum.filter(manifest, fn {path, approved_sha} ->
          not safe_manifest_path?(path) or file_sha(workdir, path) != approved_sha
        end)

      {:ok, mismatches |> Enum.map(&elem(&1, 0)) |> Enum.sort()}
    end
  end

  @spec scope_violations(
          Path.t(),
          String.t(),
          Kogen.Contracts.Intent.t(),
          Project.t(),
          [String.t()],
          %{String.t() => String.t()}
        ) :: {:ok, [String.t()]} | {:error, term()}
  def scope_violations(workdir, base_sha, intent, project, allowed_extra, git_env) do
    with {:ok, changed} <- Workspace.changed_paths(workdir, base_sha, git_env) do
      prefixes = domain_prefixes(intent.domains, project.domains) ++ allowed_extra
      outside = Enum.reject(changed, &under_prefix?(&1, prefixes))
      {:ok, outside}
    end
  end

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

    if assessment.exit_level == 3 do
      {:error,
       failure(
         :environment,
         :check_unavailable,
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

  defp file_sha(root, relative_path) do
    case File.read(Path.join(root, relative_path)) do
      {:ok, contents} -> :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)
      {:error, _reason} -> nil
    end
  end

  defp safe_manifest_path?(path) do
    Path.type(path) == :relative and ".." not in Path.split(path) and path not in ["", "."]
  end

  defp domain_prefixes(domains, mapping) do
    Enum.flat_map(domains, &Map.get(mapping, &1, []))
  end

  defp under_prefix?(path, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, String.trim_trailing(prefix, "/") <> "/")
    end)
  end

  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
