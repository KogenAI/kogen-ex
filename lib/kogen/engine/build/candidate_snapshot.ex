defmodule Kogen.Engine.Build.CandidateSnapshot do
  @moduledoc false

  alias Kogen.Engine.Build.GateSummary
  alias Kogen.Engine.Build.Session
  alias Kogen.Harness.Result, as: HarnessResult
  alias Kogen.State
  alias Kogen.Workspace

  @red_reasons [:unchanged, :repair_cap, :turn_cap, :wall_cap, :gate_red]

  @spec before_escalation(Session.t(), term()) :: :ok | {:error, term()}
  def before_escalation(%Session{} = session, reason) when reason in @red_reasons do
    if red_gate?(session), do: persist(session, reason), else: :ok
  end

  def before_escalation(_session, _reason), do: :ok

  @spec before_finish(Session.t(), atom(), term()) :: :ok | {:error, term()}
  def before_finish(%Session{} = session, :failed, reason) when reason in @red_reasons do
    if red_gate?(session), do: persist(session, reason), else: :ok
  end

  def before_finish(_session, _status, _reason), do: :ok

  defp persist(%Session{} = session, reason) do
    excluded_paths =
      session.approval.protected_manifest |> Map.keys() |> Enum.uniq() |> Enum.sort()

    filename = candidate_filename(session.attempt)
    path = Path.join(session.run_dir, filename)

    with {:ok, diff} <-
           Workspace.diff_excluding(
             session.workdir,
             session.base_sha,
             excluded_paths,
             session.git_env
           ),
         {:ok, changed_paths} <-
           Workspace.changed_paths(session.workdir, session.base_sha, session.git_env),
         :ok <- File.write(path, diff, [:binary]),
         :ok <- File.chmod(path, 0o600) do
      State.record(session.run, %{
        event: :candidate_diff,
        attempt: session.attempt,
        reason: reason,
        candidate_diff: filename,
        excluded_paths: Enum.filter(changed_paths, &(&1 in excluded_paths)),
        red_checks: red_checks(session.last_harness),
        acceptance_items: acceptance_items(session)
      })
    end
  end

  defp candidate_filename(:builder), do: "candidate.diff"
  defp candidate_filename(attempt), do: "candidate-#{attempt}.diff"

  defp red_gate?(%Session{last_harness: %HarnessResult{outcome: outcome}}),
    do: outcome in [:gate_red, :turn_cap, :wall_cap]

  defp red_gate?(_session), do: false

  defp red_checks(%HarnessResult{gate: gate}) when is_map(gate) do
    gate
    |> GateSummary.compact()
    |> Map.get(:checks, [])
    |> Enum.filter(&(is_integer(&1.exit_level) and &1.exit_level > 0))
  end

  defp red_checks(_result), do: []

  defp acceptance_items(%Session{} = session) do
    rows = Map.new(session.acceptance || [], &{&1.tag, &1.status})

    Enum.map(session.intent.acceptance, fn item ->
      Map.put(
        %{
          id: item.id,
          text: item.text,
          verify: item.verify,
          domain: item.domain
        },
        :status,
        Map.get(rows, "#{session.intent.slug}/#{item.id}")
      )
    end)
  end
end
