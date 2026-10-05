defmodule Kogen.Engine.Build.CheckStage do
  @moduledoc false

  # Final verification: configured checks plus the acceptance ledger. Acceptance items the
  # auditor demoted no longer count; with an auditor, a Candidate red only on acceptance
  # items fails as `:acceptance_red` so the Cycle can audit it.

  alias Kogen.Build.Demotion
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.Session
  alias Kogen.State

  @no_change_item_passed "no_change_item_passed"

  @spec verify(Session.t()) :: {:ok, map(), map()} | {:error, Failure.t() | term()}
  def verify(%Session{} = session) do
    with {:ok, checks} <-
           Kogen.Checks.run_all(
             session.workdir,
             session.project,
             session.run_dir,
             session.process_env,
             session.git_env,
             %{sandbox: session.sandbox, check_baseline: session.approval.check_baseline}
           ),
         {:ok, acceptance} <-
           Kogen.Checks.acceptance(
             session.workdir,
             session.intent,
             session.run_dir,
             session.process_env,
             session.git_env,
             session.sandbox
           ),
         :ok <- record(session, checks, acceptance) do
      {:ok, checks, acceptance}
    end
  end

  @spec passed(Session.t(), map(), map()) :: :ok | {:error, Failure.t()}
  def passed(%Session{} = session, checks, acceptance) do
    remaining = remaining(session, acceptance)

    cond do
      checks.status == :pass and remaining == [] ->
        :ok

      checks.status == :pass and Recipe.auditor(session.request.recipe) != nil ->
        {:error, failure(:acceptance_red, "acceptance=#{inspect({:fail, remaining})}")}

      true ->
        {:error, failure(:verification_failed, detail(checks, acceptance))}
    end
  end

  @doc "Failing acceptance ids that still count after demotion."
  @spec remaining(Session.t(), map()) :: [String.t()]
  def remaining(%Session{} = session, %{status: status} = acceptance) do
    left =
      case status do
        :pass -> []
        {:fail, ids} -> Demotion.remaining(ids, Enum.map(session.demoted, & &1.id))
      end

    if left == [] and session.demoted != [] and not change_item_passed?(session, acceptance),
      do: [@no_change_item_passed],
      else: left
  end

  @doc "Marker for a Candidate that passes no non-demoted change item; it can never be green."
  @spec no_change_item_passed() :: String.t()
  def no_change_item_passed, do: @no_change_item_passed

  # Demotion cannot turn a Candidate green unless it passes at least one change item (an
  # Acceptance item verified by a test that was red on the base).
  defp change_item_passed?(session, acceptance) do
    slug = session.intent.slug
    change = for %{verify: :test, id: id} <- session.intent.acceptance, do: "#{slug}/#{id}"
    passed = for %{status: :passed, tag: tag} <- Map.get(acceptance, :ledger, []), do: tag
    change == [] or Enum.any?(change, &(&1 in passed))
  end

  defp detail(checks, acceptance) do
    feedback = Map.get(checks, :feedback, "")
    status = "acceptance=#{inspect(acceptance.status)}"

    if feedback == "",
      do: "checks=#{inspect(checks.status)} " <> status,
      else: feedback <> "\n" <> status
  end

  defp record(session, checks, acceptance) do
    with :ok <-
           State.record(session.run, %{
             event: :check_result,
             result: checks.status,
             receipts: checks.receipts
           }) do
      State.record(session.run, %{
        event: :acceptance_result,
        result: acceptance_status(acceptance.status),
        ledger: acceptance.ledger
      })
    end
  end

  defp acceptance_status(:pass), do: :pass
  defp acceptance_status({:fail, ids}), do: %{status: :fail, failed_ids: ids}

  defp failure(reason, detail), do: %Failure{class: :candidate, reason: reason, detail: detail}
end
