defmodule Kogen.Engine.Build.Reviewer do
  @moduledoc false

  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProviderError
  alias Kogen.Engine.Build.Session
  alias Kogen.Engine.Build.StageRunner
  alias Kogen.Harness
  alias Kogen.State
  alias Kogen.Workspace

  @spec run(Session.t()) ::
          {:ok, Session.t(), [term()]} | {:error, Session.t(), Failure.t()}
  def run(%Session{} = session) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, diff} <- diff(session),
         summary = %{
           checks: session.receipts,
           acceptance: session.acceptance,
           findings: Enum.map(session.scope_warnings, & &1.finding)
         },
         {:ok, result} <-
           Harness.review(harness_opts(session), session.intent_text, diff, summary),
         :ok <- record_model(session, result.usage, elapsed(started_at)) do
      reviewed_session(session, result)
    else
      {:error, %ProviderError{} = error} -> fail(session, provider_failure(error))
      {:error, %Failure{} = failure} -> fail(session, failure)
      {:error, reason} -> fail(session, harness_failure(reason))
    end
  end

  defp reviewed_session(session, result) do
    if result.verdict == :revise do
      detail = Enum.join(result.findings, "\n")
      failure = %Failure{class: :candidate, reason: :review_revise, detail: detail}
      Kogen.Engine.Build.CheckProposals.observe(session, failure, :review)
      session = %{session | failure: failure, failure_text: detail}
      {:ok, session, [{:review, result.verdict, result.findings}]}
    else
      session = %{session | failure: nil, failure_text: nil}
      {:ok, session, [{:review, result.verdict, result.findings}]}
    end
  end

  defp diff(session), do: Workspace.diff(session.workdir, session.base_sha, session.git_env)

  defp harness_opts(session), do: StageRunner.harness_options(session)

  defp record_model(session, usage, wall_ms) do
    {model, effort} = Recipe.role(session.request.recipe, :reviewer)

    State.record(session.run, %{
      event: :model_stage,
      stage: :review,
      model: model,
      effort: effort,
      attempt: session.attempt,
      tokens: usage,
      wall_ms: wall_ms
    })
  end

  defp elapsed(started_at), do: max(System.monotonic_time(:millisecond) - started_at, 0)

  defp fail(session, %Failure{} = failure) do
    State.record(session.run, %{
      event: :stage_failure,
      stage: :review,
      class: failure.class,
      reason: failure.reason,
      detail: failure.detail
    })

    {:error, %{session | failure: failure, failure_text: failure.detail}, failure}
  end

  defp provider_failure(%ProviderError{class: :login} = error),
    do: %Failure{class: :environment, reason: :login, detail: error.message}

  defp provider_failure(%ProviderError{} = error),
    do: %Failure{class: :provider, reason: error.class, detail: error.message}

  defp harness_failure(%{reason: reason, detail: detail})
       when is_atom(reason) and is_binary(detail) do
    class = if reason in [:command_missing, :process_failed], do: :environment, else: :controller
    %Failure{class: class, reason: reason, detail: detail}
  end

  defp harness_failure(reason),
    do: %Failure{class: :controller, reason: :review_failed, detail: inspect(reason)}
end
