defmodule Kogen.Engine.Build.StageRunner do
  @moduledoc false

  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProviderError
  alias Kogen.Engine.Build.Commit
  alias Kogen.Engine.Build.GateSummary
  alias Kogen.Engine.Build.GateSupport
  alias Kogen.Engine.Build.Guard
  alias Kogen.Engine.Build.PhaseTiming, as: Timing
  alias Kogen.Engine.Build.Reviewer
  alias Kogen.Engine.Build.Session
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Result, as: HarnessResult
  alias Kogen.State

  @spec run(atom(), map(), Session.t()) ::
          {:ok, Session.t(), [term()]}
          | {:error, Session.t(), Failure.t()}
          | {:base_moved, Session.t()}
  def run(:context, _args, session), do: context(session)
  def run(:plan, _args, session), do: plan(session)
  def run(:develop, args, session), do: develop(args, session)

  def run(:fix, _args, s), do: Timing.measure(s, "build", "fix-loop", fn -> fix(s) end)

  def run(:check, _args, session), do: checks(session)
  def run(:review, _args, session), do: Reviewer.run(session)
  def run(:commit, _args, session), do: Commit.run(session)
  def run(:land, args, session), do: Commit.land(args, session)

  @spec harness_options(Session.t()) :: Opts.t()
  def harness_options(session), do: GateSupport.harness_options(session)

  defp context(session) do
    case guard(session) do
      :ok -> context_after_guard(session)
      {:error, %Failure{} = failure} -> fail(session, :context, failure)
    end
  end

  defp context_after_guard(session) do
    started_at = System.monotonic_time(:millisecond)
    {model, effort} = Recipe.role(session.request.recipe, :context)

    with :ok <- GateSupport.red_on_base(session),
         {:ok, pack} <- Harness.context_pack(harness_options(session), session.intent_text),
         :ok <-
           record_model(session, :context, model, effort, pack.usage, elapsed(started_at)) do
      {:ok, %{session | pack: pack, failure: nil, failure_text: nil},
       [{:stage_ok, :context, %{}}]}
    else
      {:error, %Failure{} = failure} ->
        fail(session, :context, base_check_failure(failure))

      {:error, %ProviderError{} = error} ->
        fail(session, :context, provider_failure(error))

      {:error, reason} ->
        fail(session, :context, harness_failure(reason))
    end
  end

  defp plan(%Session{pack: nil} = session) do
    case preflight(session) do
      :ok -> plan_provider(session)
      {:error, %Failure{} = failure} -> fail(session, :plan, failure)
    end
  end

  defp plan(%Session{} = session), do: plan_provider(session)

  defp plan_provider(%Session{pack: pack} = session) do
    started_at = System.monotonic_time(:millisecond)
    {model, effort} = Recipe.role(session.request.recipe, :planner)

    case Harness.plan(harness_options(session), pack, session.intent_text) do
      {:ok, plan} ->
        case record_model(
               session,
               :plan,
               model,
               effort,
               plan.usage,
               elapsed(started_at)
             ) do
          :ok ->
            {:ok, %{session | plan: plan, failure: nil, failure_text: nil},
             [{:stage_ok, :plan, %{}}]}

          {:error, reason} ->
            fail(session, :plan, controller_failure(:state_write_failed, inspect(reason)))
        end

      {:error, %ProviderError{} = error} ->
        fail(session, :plan, provider_failure(error))

      {:error, reason} ->
        fail(session, :plan, harness_failure(reason))
    end
  end

  defp develop(args, %Session{request: %{recipe: %{name: name}}} = session)
       when name in ["direct", "direct-shell", "direct-escalate", "escalate-shell"] and
              not session.direct_preflight_complete? do
    case preflight(session) do
      :ok -> develop_harness(%{session | direct_preflight_complete?: true}, args)
      {:error, %Failure{} = failure} -> fail(session, :develop, failure)
    end
  end

  defp develop(args, %Session{} = session), do: develop_harness(session, args)

  defp develop_harness(%Session{} = session, args) do
    resume = GateSupport.resume_data(session, args)
    started_at = System.monotonic_time(:millisecond)

    case Harness.develop(harness_options(session), session.intent_text, session.plan, resume, 0) do
      {:ok, %HarnessResult{} = result} ->
        finish_develop(session, result, started_at)

      {:error, %ProviderError{} = error} ->
        fail(session, :develop, provider_failure(error))

      {:error, %Failure{} = failure} ->
        fail(session, :develop, failure)

      {:error, reason} ->
        fail(session, :develop, harness_failure(reason))
    end
  end

  defp preflight(session) do
    case guard(session) do
      :ok ->
        case GateSupport.red_on_base(session) do
          :ok -> :ok
          {:error, %Failure{} = failure} -> {:error, base_check_failure(failure)}
        end

      {:error, %Failure{} = failure} ->
        {:error, failure}
    end
  end

  defp finish_develop(session, result, started_at) do
    {model, effort} = GateSupport.builder_settings(session)

    with {:ok, tree} <- Guard.tree_hash(session.workdir, session.git_env),
         :ok <-
           record_model(
             session,
             :develop,
             model,
             effort,
             result.usage,
             elapsed(started_at)
           ),
         {:ok, gate_flakes} <- GateSupport.record_gate_flakes(session, result.gate) do
      finish_develop_result(session, result, tree, gate_flakes)
    else
      {:error, %Failure{} = failure} ->
        fail(session, :develop, failure)

      {:error, reason} ->
        fail(session, :develop, controller_failure(:workspace_failed, inspect(reason)))
    end
  end

  defp finish_develop_result(session, result, tree, gate_flakes) do
    {failure, detail} = GateSupport.gate_failure(result)
    failed_test_count = Map.get(result.gate || %{}, :failed_test_count)

    session = %{
      session
      | last_harness: result,
        flake_excused: session.flake_excused ++ gate_flakes,
        failure: failure,
        failure_text: detail
    }

    if result.outcome == :gate_environment do
      fail(session, :develop, failure || environment_failure())
    else
      {:ok, session,
       [
         {:stage_ok, :develop, %{tree: tree}},
         {:stage_ok, :done_gate,
          GateSummary.done_gate(result.gate, result.outcome, failed_test_count)}
       ]}
    end
  end

  defp environment_failure do
    %Failure{
      class: :environment,
      reason: :check_unavailable,
      detail: "The done gate could not complete its checks."
    }
  end

  defp fix(session) do
    with :ok <-
           Guard.check(
             session.workdir,
             session.base_sha,
             session.intent,
             session.project,
             manifest(session),
             session.git_env
           ),
         {:ok, _results} <-
           Kogen.Checks.fix(
             session.workdir,
             session.project,
             session.run_dir,
             session.process_env,
             session.sandbox
           ),
         :ok <- record(session, %{event: :fix_result, result: :pass}) do
      {:ok, %{session | failure: nil, failure_text: nil}, [{:stage_ok, :fix, %{}}]}
    else
      {:error, %Failure{} = failure} -> fail(session, :fix, failure)
      {:error, reason} -> fail(session, :fix, controller_failure(:fix_failed, inspect(reason)))
    end
  end

  defp checks(session) do
    with :ok <-
           Guard.check(
             session.workdir,
             session.base_sha,
             session.intent,
             session.project,
             manifest(session),
             session.git_env
           ),
         {:ok, check_result} <-
           Kogen.Checks.run_all(
             session.workdir,
             session.project,
             session.run_dir,
             session.process_env,
             session.git_env,
             %{sandbox: session.sandbox, check_baseline: session.approval.check_baseline}
           ) do
      finish_checks(session, check_result)
    else
      {:error, %Failure{} = failure} ->
        fail(session, :check, failure)
    end
  end

  defp finish_checks(session, check_result) do
    with {:ok, acceptance} <-
           Kogen.Checks.acceptance(
             session.workdir,
             session.intent,
             session.run_dir,
             session.process_env,
             session.git_env,
             session.sandbox
           ),
         :ok <- record_check_results(session, check_result, acceptance),
         :ok <- check_passed(check_result, acceptance),
         {:ok, scope_warnings} <- GateSupport.scope_warnings(session),
         :ok <- GateSupport.record_scope_warnings(session, scope_warnings) do
      {:ok,
       %{
         session
         | acceptance: acceptance.ledger,
           receipts: check_result.receipts,
           scope_warnings: scope_warnings,
           failure: nil,
           failure_text: nil
       }, [{:stage_ok, :check, %{status: :pass}}]}
    else
      {:error, %Failure{} = failure} ->
        fail(session, :check, failure)

      {:error, reason} ->
        fail(session, :check, controller_failure(:checks_failed, inspect(reason)))
    end
  end

  defp check_passed(%{status: :pass}, %{status: :pass}), do: :ok

  defp check_passed(check_result, acceptance_result) do
    check_feedback = Map.get(check_result, :feedback, "")

    detail =
      if check_feedback == "" do
        "checks=#{inspect(check_result.status)} acceptance=#{inspect(acceptance_result.status)}"
      else
        check_feedback <> "\nacceptance=#{inspect(acceptance_result.status)}"
      end

    {:error, candidate_failure(:verification_failed, detail)}
  end

  defp record_check_results(session, check_result, acceptance_result) do
    with :ok <-
           record(session, %{
             event: :check_result,
             result: check_result.status,
             receipts: check_result.receipts
           }) do
      record(session, %{
        event: :acceptance_result,
        result: acceptance_status(acceptance_result.status),
        ledger: acceptance_result.ledger
      })
    end
  end

  defp acceptance_status(:pass), do: :pass
  defp acceptance_status({:fail, ids}), do: %{status: :fail, failed_ids: ids}

  defp manifest(session), do: session.approval.protected_manifest

  defp guard(session) do
    Guard.check(
      session.workdir,
      session.base_sha,
      session.intent,
      session.project,
      manifest(session),
      session.git_env
    )
  end

  defp record_model(session, stage, model, effort, usage, wall_ms) do
    record(session, %{
      event: :model_stage,
      stage: stage,
      model: model,
      effort: effort,
      attempt: session.attempt,
      tokens: usage,
      wall_ms: wall_ms
    })
  end

  defp elapsed(started_at), do: max(System.monotonic_time(:millisecond) - started_at, 0)

  defp record(session, event), do: State.record(session.run, event)

  defp fail(session, stage, %Failure{} = failure) do
    event = %{
      event: :stage_failure,
      stage: stage,
      class: failure.class,
      reason: failure.reason,
      detail: failure.detail
    }

    case record(session, event) do
      :ok ->
        {:error, %{session | failure: failure, failure_text: failure.detail}, failure}

      {:error, reason} ->
        controller = controller_failure(:state_write_failed, inspect(reason))
        {:error, %{session | failure: controller, failure_text: controller.detail}, controller}
    end
  end

  defp base_check_failure(%Failure{} = failure) do
    %Failure{class: :environment, reason: :base_acceptance_failed, detail: failure.detail}
  end

  defp provider_failure(%ProviderError{class: :login} = error),
    do: %Failure{class: :environment, reason: :login, detail: error.message}

  defp provider_failure(%ProviderError{} = error),
    do: %Failure{class: :provider, reason: error.class, detail: error.message}

  defp harness_failure(%{reason: reason, detail: detail})
       when is_atom(reason) and is_binary(detail) do
    class =
      if reason in [:command_missing, :process_failed, :log_directory_failed],
        do: :environment,
        else: :controller

    %Failure{class: class, reason: reason, detail: detail}
  end

  defp harness_failure(reason), do: controller_failure(:harness_failed, inspect(reason))

  defp candidate_failure(reason, detail),
    do: %Failure{class: :candidate, reason: reason, detail: detail}

  defp controller_failure(reason, detail),
    do: %Failure{class: :controller, reason: reason, detail: detail}
end
