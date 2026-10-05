defmodule Kogen.Runner.Ladder do
  @moduledoc false

  # Runs ladder rungs on fresh Candidates: records each rung's time and cost, keeps every red
  # Candidate for the selector, enforces the whole-Build wall budget, and runs parallel
  # members side by side.

  alias Kogen.Build.Cycle
  alias Kogen.Build.Demotion
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.CandidateSnapshot
  alias Kogen.Engine.Build.Escalation
  alias Kogen.Engine.Build.Session
  alias Kogen.State

  @spec escalate(Session.t(), map()) ::
          {:ok, Session.t()}
          | {:budget_exhausted, Session.t()}
          | {:error, Session.t(), Failure.t()}
  def escalate(%Session{request: %{recipe: recipe}} = session, args) do
    cond do
      Recipe.ladder(recipe) == nil -> Escalation.reset_candidate(session, Map.get(args, :trigger))
      budget_spent?(session) -> {:budget_exhausted, session}
      true -> next_rung(session, args)
    end
  end

  @doc "Records the current rung's outcome with its wall time and model usage."
  @spec rung_finished(Session.t(), atom(), term()) :: :ok | {:error, term()}
  def rung_finished(%Session{rung: nil}, _result, _reason), do: :ok
  def rung_finished(%Session{rung_started_at: nil}, _result, _reason), do: :ok

  def rung_finished(%Session{} = session, result, reason) do
    {model, effort} = Recipe.rung_builder(session.request.recipe, session.rung)

    tokens =
      case State.attempt_usage(session.run, session.attempt) do
        {:ok, usage} -> usage.tokens
        {:error, reason} -> %{unavailable: inspect(reason)}
      end

    State.record(session.run, %{
      event: :rung_finished,
      attempt: session.attempt,
      rung: session.rung.name,
      model: model,
      effort: effort,
      result: result,
      reason: reason,
      wall_ms: max(System.monotonic_time(:millisecond) - (session.rung_started_at || 0), 0),
      tokens: tokens
    })
  end

  @spec remaining_ms(Session.t()) :: non_neg_integer() | :infinity
  def remaining_ms(%Session{budget_deadline: nil}), do: :infinity

  def remaining_ms(%Session{budget_deadline: deadline}),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc "Runs each parallel member on its own Candidate; the first keeps the current checkout."
  @spec parallel(Session.t(), map(), (Session.t() -> {atom(), term(), Session.t()})) ::
          {:ok, Session.t(), [map()]}
  def parallel(%Session{} = session, %{members: [first | others]}, run_member) do
    members =
      [{first, member(session, first, session)}] ++
        Enum.flat_map(others, &fresh_member(session, &1))

    results =
      members
      |> Enum.map(fn {_spec, member} -> Task.async(fn -> run_member.(member) end) end)
      |> Task.await_many(:infinity)

    outcomes = Enum.zip_with(members, results, &outcome/2)
    finished = Enum.map(results, &elem(&1, 2))

    lines =
      Enum.flat_map(finished, fn member -> Enum.map(member.lines, &"[#{label(member)}] #{&1}") end)

    {:ok, %{session | parallel_members: finished, lines: session.lines ++ lines}, outcomes}
  end

  @doc "Continues the Build with the chosen member; the others are kept as candidates."
  @spec adopt(Session.t(), term()) :: {:ok, Session.t()} | {:error, Session.t(), Failure.t()}
  def adopt(%Session{parallel_members: members} = session, attempt) do
    {[chosen], others} = Enum.split_with(members, &(&1.attempt == attempt))

    Enum.reduce_while(others, {:ok, merge(session, chosen, others)}, fn other, {:ok, acc} ->
      case CandidateSnapshot.record(other, :not_selected, :park) do
        {:ok, recorded} ->
          {:cont, {:ok, %{acc | candidates: acc.candidates ++ recorded.candidates}}}

        {:error, reason} ->
          {:halt, {:error, acc, controller(:candidate_snapshot_failed, reason)}}
      end
    end)
  end

  defp next_rung(session, args) do
    with :ok <- rung_finished(session, :failed, Map.get(args, :trigger)),
         {:ok, recorded} <- CandidateSnapshot.record(session, Map.get(args, :trigger), :park),
         {:ok, fresh} <- fresh(recorded, args.attempt) do
      rung = Recipe.rung(session.request.recipe, args.index)
      {:ok, start_rung(fresh, rung, args.attempt, session.plan)}
    else
      {:error, %Session{} = failed, %Failure{} = failure} -> {:error, failed, failure}
      {:error, reason} -> {:error, session, controller(:candidate_snapshot_failed, reason)}
    end
  end

  defp fresh(session, attempt),
    do: Escalation.fresh_candidate(session, build_id(session, attempt))

  defp start_rung(session, rung, attempt, plan) do
    %{
      session
      | attempt: attempt,
        rung: rung,
        plan: if(rung.input == :plan, do: plan),
        rung_started_at: System.monotonic_time(:millisecond)
    }
  end

  defp member(session, spec, parent) do
    cycle =
      Cycle.new(%{
        approval: parent.approval,
        repairs: 2,
        recipe: parent.request.recipe,
        rung: spec.index,
        sub: true
      })

    %{start_rung(session, spec.rung, spec.attempt, parent.plan) | cycle: cycle, lines: []}
  end

  # A member whose checkout cannot be prepared is skipped; the others still run.
  defp fresh_member(session, spec) do
    case fresh(session, spec.attempt) do
      {:ok, fresh} -> [{spec, member(fresh, spec, session)}]
      {:error, _session, _failure} -> []
    end
  end

  defp outcome({spec, _member}, {status, reason, finished}) do
    _recorded = rung_finished(finished, status, reason)

    diff =
      case CandidateSnapshot.diff(finished) do
        {:ok, diff} -> diff
        {:error, _reason} -> ""
      end

    %{
      index: spec.index,
      attempt: spec.attempt,
      status: if(status == :green, do: :green, else: :failed),
      reason: reason,
      findings: finished.cycle.last_gate_findings,
      metrics: CandidateSnapshot.metrics(finished, diff)
    }
  end

  defp merge(session, chosen, others) do
    demoted = Enum.uniq_by(Enum.flat_map([chosen | others], & &1.demoted), & &1.id)
    added = Enum.map(demoted, & &1.id) -- Enum.map(chosen.demoted, & &1.id)

    %{
      chosen
      | cycle: session.cycle,
        lines: session.lines,
        candidates: session.candidates,
        parallel_members: [],
        rung_started_at: nil,
        demoted: demoted,
        audited: Enum.reduce(others, chosen.audited, &Map.merge(&1.audited, &2)),
        project: Demotion.exclude(chosen.project, session.approval.slug, added)
    }
  end

  defp budget_spent?(session), do: remaining_ms(session) == 0

  defp build_id(session, attempt), do: "#{session.run.id}-#{attempt}"

  defp label(%Session{attempt: :builder}), do: "builder"
  defp label(%Session{attempt: attempt}), do: to_string(attempt)

  defp controller(reason, detail),
    do: %Failure{class: :controller, reason: reason, detail: inspect(detail)}
end
