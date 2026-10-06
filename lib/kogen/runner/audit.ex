defmodule Kogen.Runner.Audit do
  @moduledoc false

  # The test auditor stage: the acceptance ledger names the failing items, one auditor call
  # judges those not judged yet, and over-strict or contradicting tests are demoted to
  # advisory for the rest of this Build.

  alias Kogen.Build.Demotion
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.ProviderError
  alias Kogen.Contracts.RolePrompt
  alias Kogen.Engine.Build.CandidateSnapshot
  alias Kogen.Engine.Build.CheckStage
  alias Kogen.Engine.Build.GateSupport
  alias Kogen.Engine.Build.Session
  alias Kogen.Harness
  alias Kogen.Runner.Auditor
  alias Kogen.State

  @spec run(map(), Session.t()) :: {:ok, Session.t(), [term()]}
  def run(_args, %Session{} = session) do
    case Kogen.Checks.acceptance(
           session.workdir,
           session.intent,
           session.run_dir,
           session.process_env,
           session.git_env,
           session.sandbox
         ) do
      {:ok, acceptance} ->
        failing =
          CheckStage.remaining(session, acceptance) --
            ["suite", CheckStage.no_change_item_passed()]

        unaudited = Enum.reject(failing, &Map.has_key?(session.audited, &1))
        session = judge(session, unaudited)
        remaining = CheckStage.remaining(session, acceptance)
        session = %{session | acceptance_failures: remaining}
        session = %{session | failure_text: note(session)}
        {:ok, session, [{:stage_ok, :audit, %{remaining: length(remaining)}}]}

      {:error, failure} ->
        skipped(session, failure)
    end
  end

  defp judge(session, []), do: session

  defp judge(session, ids) do
    started_at = System.monotonic_time(:millisecond)

    request = %RolePrompt{
      stage: :audit,
      role: :auditor,
      instructions: Auditor.instructions(),
      text: Auditor.input(input(session, ids))
    }

    case Harness.ask(GateSupport.harness_options(session), request) do
      {:ok, %{text: text, usage: usage}} ->
        {model, effort} = Recipe.auditor(session.request.recipe)
        wall_ms = max(System.monotonic_time(:millisecond) - started_at, 0)
        _recorded = record_model(session, model, effort, usage, wall_ms)
        Enum.reduce(Auditor.verdicts(text, ids), session, &apply_verdict(&2, &1))

      {:error, reason} ->
        _recorded = record_failure(session, reason)
        session
    end
  end

  defp apply_verdict(session, %{id: id, verdict: verdict, reason: reason}) do
    _recorded =
      State.record(session.run, %{
        event: if(verdict == :valid, do: :acceptance_upheld, else: :acceptance_demoted),
        attempt: session.attempt,
        item: id,
        verdict: verdict,
        reason: reason
      })

    session = %{session | audited: Map.put(session.audited, id, verdict)}

    if verdict == :valid do
      session
    else
      %{
        session
        | demoted: session.demoted ++ [%{id: id, verdict: verdict, reason: reason}],
          project: Demotion.exclude(session.project, session.approval.slug, [id])
      }
    end
  end

  defp input(session, ids) do
    slug = session.approval.slug

    diff =
      case CandidateSnapshot.diff(session) do
        {:ok, diff} -> diff
        {:error, reason} -> "Candidate diff unavailable: #{inspect(reason)}"
      end

    %{
      failing: ids,
      request: session.intent.request || session.intent_text,
      test_path: "test/acceptance/#{slug}_test.exs",
      test_source:
        Map.get(session.approval.acceptance_files, ".kogen/acceptance/#{slug}_test.exs"),
      failure: session.failure_text || "",
      diff_summary: diff
    }
  end

  # Repairs see which red acceptance tests the auditor upheld against the Request.
  defp note(%Session{acceptance_failures: []} = session), do: session.failure_text

  defp note(session) do
    upheld =
      for id <- session.acceptance_failures, Map.get(session.audited, id) == :valid, do: id

    upheld_note =
      if upheld == [],
        do: "",
        else:
          "\n\nKogen's test auditor checked these failing acceptance items against the " <>
            "Request and upheld them; change the implementation, not the tests: " <>
            Enum.join(upheld, ", ")

    zero_note =
      if CheckStage.no_change_item_passed() in session.acceptance_failures,
        do:
          "\n\nNo acceptance item for the requested change passes yet; implement the " <>
            "Request so that at least one of them does.",
        else: ""

    (session.failure_text || "") <> upheld_note <> zero_note
  end

  defp skipped(session, failure) do
    _recorded = record_failure(session, failure)
    {:ok, session, [{:stage_ok, :audit, %{remaining: :unknown}}]}
  end

  defp record_model(session, model, effort, usage, wall_ms) do
    State.record(session.run, %{
      event: :model_stage,
      stage: :audit,
      model: model,
      effort: effort,
      attempt: session.attempt,
      tokens: usage,
      wall_ms: wall_ms
    })
  end

  defp record_failure(session, reason) do
    State.record(session.run, %{
      event: :stage_failure,
      stage: :audit,
      class: if(is_struct(reason, ProviderError), do: :provider, else: :controller),
      reason: :audit_failed,
      detail: inspect(reason)
    })
  end
end
