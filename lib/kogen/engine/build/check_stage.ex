defmodule Kogen.Engine.Build.CheckStage do
  @moduledoc false

  # Final verification: configured checks plus the acceptance ledger. Acceptance items the
  # auditor demoted no longer count; with an auditor, a Candidate red only on acceptance
  # items fails as `:acceptance_red` so the Cycle can audit it.

  alias Kogen.Build.Demotion
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.Guard
  alias Kogen.Engine.Build.Session
  alias Kogen.State
  alias Kogen.Workspace

  @no_change_item_passed "no_change_item_passed"

  @spec verify(Session.t()) :: {:ok, map(), map()} | {:error, Failure.t() | term()}
  def verify(%Session{} = session) do
    with {:ok, fix_receipts} <- final_pass(session),
         {:ok, checks} <- run_checks(session),
         {:ok, acceptance} <- acceptance(session),
         :ok <- unchanged(session, checks.tree),
         checks = %{checks | receipts: fix_receipts ++ checks.receipts},
         :ok <- record(session, checks, acceptance) do
      {:ok, checks, acceptance}
    end
  end

  defp run_checks(session) do
    Kogen.Checks.run_all(
      session.workdir,
      session.project,
      session.run_dir,
      session.process_env,
      session.git_env,
      %{
        sandbox: session.sandbox,
        base: session.base_sha,
        check_baseline: session.approval.check_baseline,
        changed_ranges: fn ->
          Workspace.changed_line_ranges(session.workdir, session.base_sha, session.git_env)
        end
      }
    )
  end

  def final_pass(session) do
    with {:ok, results} <-
           Kogen.Checks.final_pass(
             session.workdir,
             session.project,
             session.run_dir,
             session.process_env,
             session.sandbox,
             session.approval.check_baseline
           ),
         {:ok, tree} <- Workspace.tree_hash(session.workdir, session.git_env),
         {:ok, receipts} <- Kogen.Checks.final_pass_receipts(tree, session.project, results),
         verdict = Kogen.Checks.final_pass_passed(results),
         :ok <-
           State.record(session.run, %{
             event: :fix_result,
             result: if(verdict == :ok, do: :pass, else: :fail),
             receipts: receipts
           }),
         :ok <- verdict,
         :ok <- guard(session) do
      {:ok, receipts}
    end
  end

  defp guard(session) do
    Guard.check(
      session.workdir,
      session.base_sha,
      session.intent,
      session.project,
      session.approval.protected_manifest,
      session.git_env
    )
  end

  defp unchanged(session, expected) do
    with {:ok, tree} <- Workspace.tree_hash(session.workdir, session.git_env) do
      if tree == expected,
        do: :ok,
        else: {:error, failure(:verification_failed, "Acceptance changed the verified tree.")}
    end
  end

  # A raw Intent without Acceptance items has no ledger; its gate is the project's checks.
  defp acceptance(%Session{intent: %{source: :raw, acceptance: []}}),
    do: {:ok, %{status: :pass, ledger: []}}

  defp acceptance(%Session{} = session) do
    Kogen.Checks.acceptance(
      session.workdir,
      session.intent,
      session.run_dir,
      session.process_env,
      session.git_env,
      session.sandbox
    )
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
    timing =
      Kogen.Contracts.GateTiming.combine([Map.get(checks, :timing), Map.get(acceptance, :timing)])

    Kogen.Checks.Timing.record(session.run_dir, timing)

    with :ok <-
           State.record(session.run, %{
             event: :check_result,
             result: checks.status,
             timing: Map.get(checks, :timing),
             receipts: checks.receipts
           }) do
      State.record(session.run, %{
        event: :acceptance_result,
        result: acceptance_status(acceptance.status),
        timing: timing,
        ledger: acceptance.ledger
      })
    end
  end

  defp acceptance_status(:pass), do: :pass
  defp acceptance_status({:fail, ids}), do: %{status: :fail, failed_ids: ids}

  defp failure(reason, detail), do: %Failure{class: :candidate, reason: reason, detail: detail}
end
