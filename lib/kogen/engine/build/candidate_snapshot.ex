defmodule Kogen.Engine.Build.CandidateSnapshot do
  @moduledoc false

  alias Kogen.Build.GateSummary
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

  @doc """
  Records a ladder Candidate for the selector: commits its tree, writes its diff and metrics,
  and with `:park` pushes it under `refs/kogen/parked/<run>-<attempt>` and removes the checkout.
  Candidates without changes are not kept.
  """
  @spec record(Session.t(), term(), :park | :keep) :: {:ok, Session.t()} | {:error, term()}
  def record(%Session{} = session, reason, disposal) do
    case diff(session) do
      {:ok, ""} -> with :ok <- dispose(session, disposal, false), do: {:ok, session}
      {:ok, _diff} -> record_changed(session, reason, disposal)
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_changed(session, reason, disposal) do
    with :ok <- commit_tree(session),
         {:ok, commit} <- Workspace.rev_parse(session.workdir, "HEAD", session.git_env),
         {:ok, diff} <-
           persist(session, reason, &%{commit: commit, metrics: metrics(session, &1)}),
         :ok <- dispose(session, disposal, true) do
      candidate = %{
        attempt: session.attempt,
        status: :failed,
        reason: reason,
        commit: commit,
        metrics: metrics(session, diff),
        failing: failing(session),
        findings: Enum.take(session.cycle.last_gate_findings, 5)
      }

      {:ok, %{session | candidates: session.candidates ++ [candidate]}}
    end
  end

  @doc "Commits uncommitted Candidate changes so the tree can be pushed or parked."
  @spec commit_tree(Session.t()) :: :ok | {:error, term()}
  def commit_tree(%Session{} = session) do
    with {:ok, working_tree} <- Workspace.tree_hash(session.workdir, session.git_env),
         {:ok, head_tree} <- Workspace.rev_parse(session.workdir, "HEAD^{tree}", session.git_env) do
      if working_tree == head_tree do
        :ok
      else
        case Workspace.commit(session.workdir, "Preserve Kogen candidate", [], session.git_env) do
          {:ok, _sha} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc "The Candidate's diff against the base, without approved protected paths."
  @spec diff(Session.t()) :: {:ok, binary()} | {:error, term()}
  def diff(%Session{} = session) do
    Workspace.diff_excluding(
      session.workdir,
      session.base_sha,
      excluded_paths(session),
      session.git_env
    )
  end

  @doc "Selector metrics for the Candidate's last gate and its diff against the base."
  @spec metrics(Session.t(), binary()) :: map()
  def metrics(%Session{} = session, diff) do
    gate = session.last_harness && session.last_harness.gate
    metrics = gate |> GateSummary.metrics(acceptance_path(session)) |> Map.from_struct()
    lines = diff |> String.split("\n") |> Enum.count(&changed_line?/1)
    metrics = Map.put(metrics, :diff_lines, lines)

    case session.acceptance_failures do
      [] -> metrics
      ids -> %{metrics | failing_acceptance: length(ids -- ["suite"])}
    end
  end

  defp failing(session) do
    gate = session.last_harness && session.last_harness.gate

    acceptance =
      if session.acceptance_failures == [],
        do: acceptance_findings(gate, acceptance_path(session)),
        else: session.acceptance_failures

    %{acceptance: acceptance, red_checks: Enum.map(red_checks(session.last_harness), & &1.name)}
  end

  defp acceptance_findings(gate, path) when is_map(gate) do
    (Map.get(gate, :checks, []) ++ Map.get(gate, :fixes, []))
    |> Enum.flat_map(&Map.get(&1, :findings, []))
    |> Enum.filter(&(Map.get(&1, :path) == path))
    |> Enum.map(&(Map.get(&1, :symbol) || "#{path}:#{Map.get(&1, :line)}"))
    |> Enum.uniq()
  end

  defp acceptance_findings(_gate, _path), do: []

  defp dispose(_session, :keep, _changed?), do: :ok
  defp dispose(session, :park, false), do: Workspace.destroy(session.workdir)

  defp dispose(session, :park, true) do
    Workspace.park(
      session.workdir,
      session.request.origin,
      "#{session.run.id}-#{session.attempt}",
      session.git_env
    )
  end

  defp changed_line?("+++" <> _rest), do: false
  defp changed_line?("---" <> _rest), do: false
  defp changed_line?("+" <> _rest), do: true
  defp changed_line?("-" <> _rest), do: true
  defp changed_line?(_line), do: false

  # Approved protected paths and the installed Intent files are not the Candidate's work.
  defp excluded_paths(%Session{approval: approval}) do
    intent_files = [
      ".kogen/intents/#{approval.slug}/intent.md",
      ".kogen/acceptance/#{approval.slug}_test.exs",
      "test/acceptance/#{approval.slug}_test.exs"
    ]

    (Map.keys(approval.protected_manifest) ++ intent_files) |> Enum.uniq() |> Enum.sort()
  end

  defp acceptance_path(session), do: "test/acceptance/#{session.approval.slug}_test.exs"

  defp persist(%Session{} = session, reason) do
    case persist(session, reason, fn _diff -> %{} end) do
      {:ok, _diff} -> :ok
      error -> error
    end
  end

  defp persist(%Session{} = session, reason, extra) do
    session = Kogen.Engine.Build.AcceptanceProgress.capture(session)
    excluded_paths = excluded_paths(session)
    filename = candidate_filename(session.attempt)
    path = Path.join(session.run_dir, filename)

    with {:ok, diff} <- diff(session),
         {:ok, changed_paths} <-
           Workspace.changed_paths(session.workdir, session.base_sha, session.git_env),
         :ok <- File.write(path, diff, [:binary]),
         :ok <- File.chmod(path, 0o600),
         :ok <-
           State.record(
             session.run,
             Map.merge(
               %{
                 event: :candidate_diff,
                 attempt: session.attempt,
                 reason: reason,
                 candidate_diff: filename,
                 excluded_paths: Enum.filter(changed_paths, &(&1 in excluded_paths)),
                 red_checks: red_checks(session.last_harness),
                 acceptance_items: acceptance_items(session)
               },
               extra.(diff)
             )
           ) do
      {:ok, diff}
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
