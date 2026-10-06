defmodule Kogen.Engine.Build.CheckStage do
  @moduledoc false

  # Final verification: configured checks plus the acceptance ledger. Acceptance items the
  # auditor demoted no longer count; with an auditor, a Candidate red only on acceptance
  # items fails as `:acceptance_red` so the Cycle can audit it.

  alias Kogen.Build.Verification
  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.Guard
  alias Kogen.Engine.Build.Session
  alias Kogen.State
  alias Kogen.Workspace

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
      Verification.unchanged(expected, tree)
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
  def passed(%Session{request: %{recipe: recipe}} = session, checks, acceptance),
    do: Verification.passed(recipe, remaining(session, acceptance), checks, acceptance)

  @doc "Failing acceptance ids that still count after demotion."
  @spec remaining(Session.t(), map()) :: [String.t()]
  def remaining(%Session{} = session, %{status: _status} = acceptance),
    do: Verification.remaining(session.intent, session.demoted, acceptance)

  @doc "Marker for a Candidate that passes no non-demoted change item; it can never be green."
  @spec no_change_item_passed() :: String.t()
  defdelegate no_change_item_passed(), to: Verification

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
        result: Verification.acceptance_status(acceptance.status),
        timing: timing,
        ledger: acceptance.ledger
      })
    end
  end
end
