defmodule Kogen.Shaper.Runner do
  @moduledoc false

  alias Kogen.Checks.ShapeFormatRequest
  alias Kogen.Checks.ShapeValidation
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.Redact
  alias Kogen.Contracts.ShapeWarning
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Harness.ShapePass
  alias Kogen.Proc
  alias Kogen.Project, as: ProjectDomain
  alias Kogen.Shaper.Request
  alias Kogen.Shaper.Result
  alias Kogen.Shaper.Runner.State
  alias Kogen.Shaper.Setup
  alias Kogen.Shaper.ShapeWarnings
  alias Kogen.Shaper.Validation

  @max_repairs 4

  @spec run(Request.t()) :: {:ok, Result.t()} | {:error, term()}
  def run(%Request{} = request) do
    with :ok <- Request.validate(request),
         {:ok, project} <- ProjectDomain.load(request.workdir),
         {:ok, opts} <- harness_options(request, project),
         :ok <- ShapeWarnings.clear(request.workdir, request.slug),
         :ok <- Setup.run(request, project) do
      deadline = wall_deadline(request.limits.wall_ms)
      attempt(%State{request: request, project: project, opts: opts, deadline: deadline})
    end
  end

  defp attempt(%State{} = state) do
    request = state.request
    attempt_number = state.repairs + 1
    remaining_turns = request.limits.max_turns - state.turn_offset
    remaining_ms = remaining_ms(state.deadline)

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

      is_integer(remaining_ms) and remaining_ms < 1 ->
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

  defp wall_deadline(:infinity), do: nil
  defp wall_deadline(wall_ms), do: System.monotonic_time(:millisecond) + wall_ms

  defp remaining_ms(nil), do: :infinity
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

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

      {:error, %Failure{class: :candidate} = failure} ->
        progress(
          state.request,
          attempt_number,
          "validation_failed reason=#{failure.reason}; repair_limit_reached " <>
            "repairs=#{state.repairs}/#{@max_repairs} attempts=#{attempt_number} calls=#{length(state.calls)}"
        )

        validation_exhausted(failure, state.repairs, attempt_number, length(state.calls))

      {:error, %Failure{} = failure} ->
        progress(
          state.request,
          attempt_number,
          "validation_stopped class=#{failure.class} reason=#{failure.reason} " <>
            "repairs=#{state.repairs} attempts=#{attempt_number} calls=#{length(state.calls)}"
        )

        {:error, failure}
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
        validate_files(state.request, state.project, state.opts, attempt_number)

      {:warning, %Failure{class: :environment, reason: reason}} ->
        progress(state.request, attempt_number, "warning formatter_skipped reason=#{reason}")
        validate_files(state.request, state.project, state.opts, attempt_number)

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

  defp validate_files(request, project, opts, attempt_number) do
    intent_path = intent_path(request.slug)
    acceptance_path = acceptance_path(request.slug)

    intent_result =
      with {:ok, intent_bytes} <- read_generated(request.workdir, intent_path),
           {:ok, normalized_bytes} <-
             normalize_generated_intent(request, intent_path, intent_bytes, attempt_number) do
        Validation.intent(normalized_bytes, intent_path, project)
      end

    acceptance_result = read_generated(request.workdir, acceptance_path)

    resolve_generated_files({intent_result, acceptance_result}, request, project, opts)
  end

  defp resolve_generated_files({{:ok, intent}, {:ok, test_bytes}}, request, project, opts) do
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

  defp resolve_generated_files(
         {{:error, %Failure{class: :candidate} = intent_failure},
          {:error, %Failure{class: :candidate} = acceptance_failure}},
         _request,
         _project,
         _opts
       ) do
    {:error,
     %{
       intent_failure
       | detail: intent_failure.detail <> "\n" <> failure_output(acceptance_failure)
     }}
  end

  defp resolve_generated_files(
         {{:error, %Failure{} = failure}, _acceptance},
         _request,
         _project,
         _opts
       ), do: {:error, failure}

  defp resolve_generated_files(
         {{:ok, _intent}, {:error, %Failure{} = failure}},
         _request,
         _project,
         _opts
       ), do: {:error, failure}

  defp normalize_generated_intent(request, path, bytes, attempt_number) do
    normalized =
      bytes
      |> Validation.normalize_intent()
      |> without_generated_request()
      |> append_request(request.task)

    if normalized == bytes do
      {:ok, bytes}
    else
      case File.write(Path.join(request.workdir, path), normalized, [:binary]) do
        :ok ->
          progress(request, attempt_number, "normalized intent approach label path=#{path}")
          {:ok, normalized}

        {:error, reason} ->
          {:error,
           failure(
             :environment,
             :intent_normalization_failed,
             "Could not write normalized Intent at #{path}: #{inspect(reason)}"
           )}
      end
    end
  end

  defp without_generated_request(bytes) do
    lines = String.split(bytes, "\n", trim: false)

    case Enum.find_index(lines, &(String.trim(&1) == "## Request")) do
      nil -> bytes
      index -> lines |> Enum.take(index) |> Enum.join("\n")
    end
  end

  defp append_request(bytes, request) do
    separator = if String.ends_with?(bytes, "\n"), do: "\n", else: "\n\n"
    bytes <> separator <> "## Request\n" <> request
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

  defp validation_exhausted(%Failure{} = failure, repairs, attempts, calls) do
    {:error,
     %{
       failure
       | detail:
           "Shaper repair limit reached for #{failure.reason} after #{repairs} repair round(s), " <>
             "#{attempts} attempt(s), and #{calls} model call(s).\n" <> failure_output(failure)
     }}
  end

  defp failure_output(%Failure{} = failure),
    do: "#{failure.class}/#{failure.reason}: #{failure.detail}"

  defp intent_path(slug), do: ".kogen/intents/#{slug}/intent.md"
  defp acceptance_path(slug), do: ".kogen/acceptance/#{slug}_test.exs"
  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}

  defp limit_failure(request, attempt_number, reason, detail) do
    progress(request, attempt_number, "stopped reason=#{reason}")
    {:error, failure(:candidate, reason, detail)}
  end

  defp progress(request, attempt_number, message) do
    line = Redact.text("attempt=#{attempt_number} #{message}")
    log_path = Path.join([request.run_dir, "logs", "shaper.log"])
    _ = File.write(log_path, line <> "\n", [:append])
    IO.puts(:stderr, "shaper #{line}")
  end
end
