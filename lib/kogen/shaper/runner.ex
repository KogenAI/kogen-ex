defmodule Kogen.Shaper.Runner do
  @moduledoc false

  alias Kogen.Checks.ShapeFormatRequest
  alias Kogen.Checks.ShapeValidation
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ShapeWarning
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Harness.ShapePass
  alias Kogen.Proc
  alias Kogen.Project, as: ProjectDomain
  alias Kogen.Shaper.Request
  alias Kogen.Shaper.Result
  alias Kogen.Shaper.Runner.State
  alias Kogen.Shaper.ShapeWarnings
  alias Kogen.Shaper.Validation

  @max_repairs 4

  @spec run(Request.t()) :: {:ok, Result.t()} | {:error, term()}
  def run(%Request{} = request) do
    with :ok <- valid_request(request),
         {:ok, project} <- ProjectDomain.load(request.workdir),
         {:ok, opts} <- harness_options(request, project),
         :ok <- ShapeWarnings.clear(request.workdir, request.slug),
         :ok <- setup_project(request, project) do
      deadline = System.monotonic_time(:millisecond) + request.limits.wall_ms
      attempt(%State{request: request, project: project, opts: opts, deadline: deadline})
    end
  end

  defp setup_project(request, %Project{} = project) do
    env = Map.merge(request.env, project.env)

    case File.mkdir_p(Path.join(request.run_dir, "logs")) do
      :ok ->
        Enum.reduce_while(Enum.with_index(project.setup, 1), :ok, fn {spec, index}, :ok ->
          run_setup(spec, request, env, index)
        end)

      {:error, reason} ->
        {:error, failure(:environment, :setup_log_failed, inspect(reason))}
    end
  end

  defp run_setup(spec, request, env, index) do
    log_path = Path.join([request.run_dir, "logs", "shape-setup-#{index}-#{spec.name}.log"])

    case Proc.run(spec.argv,
           cd: request.workdir,
           env: env,
           timeout_ms: spec.timeout_ms,
           log_path: log_path
         ) do
      {:ok, %{exit_status: 0, timed_out: false}} ->
        {:cont, :ok}

      {:ok, result} ->
        detail =
          "Setup #{spec.name} failed (status=#{inspect(result.exit_status)}, timed_out=#{result.timed_out}).\n#{result.output_tail}"

        {:halt, {:error, failure(:environment, :setup_failed, detail)}}

      {:error, reason} ->
        {:halt,
         {:error,
          failure(
            :environment,
            :setup_failed,
            "Setup #{spec.name} could not run: #{inspect(reason)}"
          )}}
    end
  end

  defp attempt(%State{} = state) do
    request = state.request
    attempt_number = state.repairs + 1
    remaining_turns = request.limits.max_turns - state.turn_offset
    remaining_ms = max(state.deadline - System.monotonic_time(:millisecond), 0)

    progress(
      request,
      attempt_number,
      "started turns_used=#{state.turn_offset}/#{request.limits.max_turns} " <>
        "wall_remaining_ms=#{remaining_ms}"
    )

    cond do
      remaining_turns < 1 ->
        limit_failure(
          request,
          attempt_number,
          :shape_turn_limit,
          "Shaper exhausted its turn limit."
        )

      remaining_ms < 1 ->
        limit_failure(
          request,
          attempt_number,
          :shape_wall_limit,
          "Shaper exhausted its wall time limit."
        )

      true ->
        run_attempt(state, attempt_number, remaining_turns, remaining_ms)
    end
  end

  defp run_attempt(state, attempt_number, remaining_turns, remaining_ms) do
    opts = %{state.opts | limits: %{max_turns: remaining_turns, wall_ms: remaining_ms}}

    case Harness.shape(
           opts,
           state.request.slug,
           state.request.task,
           state.history,
           state.failure_text,
           state.turn_offset
         ) do
      {:ok, %ShapePass{} = pass} ->
        progress(
          state.request,
          attempt_number,
          "model_pass_complete turns=#{pass.turns} calls=#{length(pass.calls)}"
        )

        next = %{state | calls: state.calls ++ pass.calls}
        validate_pass(next, pass, attempt_number)

      {:error, reason} ->
        progress(state.request, attempt_number, "model_pass_failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp validate_pass(%State{} = state, %ShapePass{} = pass, attempt_number) do
    validation = validate_formatted_pass(state, pass, attempt_number)

    case validation do
      {:ok, warnings} ->
        validation_succeeded(state, attempt_number, warnings)

      {:error, %Failure{class: :candidate} = failure} when state.repairs < @max_repairs ->
        progress(
          state.request,
          attempt_number,
          "validation_failed reason=#{failure.reason}; repair_scheduled"
        )

        repair(state, pass, failure)

      {:error, %Failure{} = failure} ->
        progress(
          state.request,
          attempt_number,
          "validation_failed reason=#{failure.reason}; repair_limit_reached"
        )

        validation_exhausted(failure, state.repairs)
    end
  end

  defp validation_succeeded(state, attempt_number, warnings) do
    case ShapeWarnings.write(state.request.workdir, state.request.slug, warnings) do
      :ok ->
        Enum.each(warnings, &log_warning(state.request, attempt_number, &1))
        progress(state.request, attempt_number, "validation_passed")

        {:ok,
         result(
           state.request,
           state.calls,
           state.repairs + 1,
           state.opts,
           warnings
         )}

      {:error, %Failure{} = failure} ->
        {:error, failure}
    end
  end

  defp validate_formatted_pass(%State{} = state, %ShapePass{} = pass, attempt_number) do
    format_request = %ShapeFormatRequest{
      workdir: state.request.workdir,
      slug: state.request.slug,
      written_paths: pass.written_paths,
      project: state.project,
      run_dir: state.opts.run_dir,
      env: state.opts.env,
      sandbox: state.request.sandbox
    }

    case Kogen.Checks.format_shape_files(format_request) do
      :ok ->
        validate_files(state.request, state.project, state.opts)

      {:warning, %Failure{class: :environment, reason: reason}} ->
        progress(state.request, attempt_number, "warning formatter_skipped reason=#{reason}")
        validate_files(state.request, state.project, state.opts)

      {:error, %Failure{} = failure} ->
        {:error, failure}
    end
  end

  defp repair(%State{} = state, %ShapePass{} = pass, %Failure{} = failure) do
    next = %{
      state
      | history: pass.items,
        failure_text: failure_output(failure),
        turn_offset: state.turn_offset + pass.turns,
        repairs: state.repairs + 1
    }

    attempt(next)
  end

  defp validate_files(request, project, opts) do
    intent_path = intent_path(request.slug)
    acceptance_path = acceptance_path(request.slug)

    with {:ok, intent_bytes} <- read_generated(request.workdir, intent_path),
         {:ok, intent} <- Validation.intent(intent_bytes, intent_path),
         {:ok, test_bytes} <- read_generated(request.workdir, acceptance_path) do
      Kogen.Checks.validate_shape(%ShapeValidation{
        workdir: request.workdir,
        project: project,
        intent: intent,
        acceptance_bytes: test_bytes,
        run_dir: opts.run_dir,
        env: opts.env,
        git_env: request.git_env,
        sandbox: request.sandbox
      })
    end
  end

  defp read_generated(workdir, relative) do
    case File.read(Path.join(workdir, relative)) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :enoent} ->
        {:error,
         failure(
           :candidate,
           :generated_file_missing,
           "Cannot read #{relative}: :enoent. Write this required file at that exact path before finishing."
         )}

      {:error, reason} ->
        {:error,
         failure(
           :candidate,
           :generated_file_missing,
           "Cannot read #{relative}: #{inspect(reason)}"
         )}
    end
  end

  defp harness_options(request, %Project{} = project) do
    opts = %Opts{
      workdir: request.workdir,
      run_dir: request.run_dir,
      project: project,
      provider_mod: request.provider_mod,
      provider_config: request.provider_config,
      proc_mod: Proc,
      sandbox: request.sandbox,
      env: Map.merge(request.env, project.env),
      models: %{builder: {request.model, request.effort}, strong: {request.model, request.effort}},
      limits: request.limits
    }

    {:ok, opts}
  end

  defp valid_request(%Request{} = request) do
    cond do
      not absolute_directory?(request.workdir) ->
        {:error, :project_unavailable}

      not valid_slug?(request.slug) ->
        {:error, :invalid_slug}

      not is_binary(request.task) or String.trim(request.task) == "" ->
        {:error, :empty_task}

      not nonempty_string?(request.model) or not nonempty_string?(request.effort) ->
        {:error, :invalid_model}

      not is_binary(request.run_dir) or Path.type(request.run_dir) != :absolute ->
        {:error, :invalid_run_dir}

      true ->
        valid_runtime_options(request)
    end
  end

  defp valid_runtime_options(request) do
    cond do
      not is_map(request.env) or not is_map(request.git_env) ->
        {:error, :invalid_environment}

      not valid_limits?(request.limits) ->
        {:error, :invalid_limits}

      true ->
        :ok
    end
  end

  defp result(request, calls, rounds, opts, warnings) do
    %Result{
      slug: request.slug,
      intent_path: Path.join(request.workdir, intent_path(request.slug)),
      acceptance_path: Path.join(request.workdir, acceptance_path(request.slug)),
      calls: calls,
      rounds: rounds,
      transcript_path: Path.join(opts.run_dir, "transcript.jsonl"),
      warnings: warnings
    }
  end

  defp log_warning(request, attempt_number, %ShapeWarning{code: code, item_ids: ids}) do
    progress(request, attempt_number, "warning #{code} items=#{Enum.join(ids, ",")}")
  end

  defp validation_exhausted(%Failure{} = failure, repairs) do
    {:error,
     %Failure{
       class: :candidate,
       reason: :shaping_validation_failed,
       detail:
         "Shaper validation failed after #{repairs} repair round(s).\n" <> failure_output(failure)
     }}
  end

  defp failure_output(%Failure{} = failure),
    do: "#{failure.class}/#{failure.reason}: #{failure.detail}"

  defp absolute_directory?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.dir?(path)

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_slug?(slug),
    do: is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)

  defp valid_limits?(%{max_turns: turns, wall_ms: wall_ms}),
    do: is_integer(turns) and turns > 0 and is_integer(wall_ms) and wall_ms > 0

  defp valid_limits?(_limits), do: false

  defp intent_path(slug), do: ".kogen/intents/#{slug}/intent.md"
  defp acceptance_path(slug), do: ".kogen/acceptance/#{slug}_test.exs"
  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}

  defp limit_failure(request, attempt_number, reason, detail) do
    progress(request, attempt_number, "stopped reason=#{reason}")
    {:error, failure(:candidate, reason, detail)}
  end

  defp progress(request, attempt_number, message) do
    line = "attempt=#{attempt_number} #{message}"
    log_path = Path.join([request.run_dir, "logs", "shaper.log"])
    _ = File.write(log_path, line <> "\n", [:append])
    IO.puts(:stderr, "shaper #{line}")
  end
end
