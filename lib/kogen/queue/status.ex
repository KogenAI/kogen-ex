defmodule Kogen.Queue.Status do
  @moduledoc """
  Derives each Intent's state from its files, the origin's approval refs and landing trailers,
  and the latest Build journal. The queue is these states, never a stored list.
  """

  alias Kogen.Queue.BuildSummary
  alias Kogen.Queue.IntentStatus
  alias Kogen.Queue.StateView
  alias Kogen.State
  alias Kogen.State.Event
  alias Kogen.State.Run
  alias Kogen.Workspace

  @spec list(Path.t(), Path.t(), Path.t(), String.t(), map()) ::
          {:ok, [IntentStatus.t()]} | {:error, term()}
  def list(project_root, state_root, origin, base, git_env) do
    slugs = intent_paths(project_root)
    legacy_root = Path.join(project_root, ".kogen")

    with {:ok, current_runs} <- State.list(state_root),
         {:ok, legacy_runs} <- legacy_runs(state_root, legacy_root),
         {:ok, snapshot} <-
           Workspace.status_snapshot(
             origin,
             base,
             git_env,
             Enum.any?(current_runs ++ legacy_runs, &(&1.status == :running))
           ),
         {:ok, latest} <- latest_runs(slugs, current_runs, legacy_runs) do
      {:ok, Enum.map(slugs, &intent_status(&1, Map.get(latest, &1), snapshot))}
    end
  rescue
    ArgumentError -> {:error, :status_unavailable}
  end

  @doc "Approved Intents in the order the queue builds them: oldest approval first."
  @spec queued([IntentStatus.t()]) :: [IntentStatus.t()]
  def queued(statuses) do
    statuses
    |> Enum.filter(&(&1.status == :approved))
    |> Enum.sort_by(&{&1.approved_at || 0, &1.slug})
  end

  defp intent_paths(project_root) do
    [project_root, ".kogen", "intents", "*", "intent.md"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&Path.basename(Path.dirname(&1)))
    |> Enum.filter(&valid_slug?/1)
    |> Enum.sort()
  end

  defp legacy_runs(state_root, legacy_root) when state_root == legacy_root, do: {:ok, []}
  defp legacy_runs(_state_root, legacy_root), do: State.list(legacy_root)

  defp latest_runs(slugs, current_runs, legacy_runs) do
    current = Enum.group_by(current_runs, & &1.slug)
    legacy = Enum.group_by(legacy_runs, & &1.slug)

    Enum.reduce_while(slugs, {:ok, %{}}, fn slug, {:ok, statuses} ->
      selected_runs = Map.get(current, slug, [])
      selected_runs = if selected_runs == [], do: Map.get(legacy, slug, []), else: selected_runs

      case StateView.latest(selected_runs) do
        {:ok, latest} -> {:cont, {:ok, Map.put(statuses, slug, latest)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp intent_status(slug, latest, snapshot) do
    approval = Map.get(snapshot.approvals, slug)
    landed_sha = Map.get(snapshot.landed, slug)

    status =
      approval
      |> lifecycle_status(landed_sha, latest, snapshot.claim_run_id)
      |> interrupted(latest, approval)

    %IntentStatus{
      slug: slug,
      status: status,
      run_id: if(match?(%Run{}, latest), do: latest.id),
      landed_sha: landed_sha,
      approved_at: Map.get(snapshot.approved_at, slug),
      landed_index: Enum.find_index(snapshot.landed_order, &(&1 == slug)),
      detail: detail(status, latest),
      started_at: started_at(status, latest)
    }
  end

  defp lifecycle_status(_approval, landed_sha, _latest, _claim_run_id) when is_binary(landed_sha),
    do: :landed

  defp lifecycle_status(approval, nil, latest, claim_run_id) do
    cond do
      claimed_run?(latest, claim_run_id) -> :building
      terminal_for_approval?(latest, approval, :parked) -> :parked
      terminal_for_approval?(latest, approval, :failed) -> :failed
      is_binary(approval) -> :approved
      true -> :draft
    end
  end

  # A SIGTERM-ended Build reads as interrupted, whether recovery closed it yet or not.
  defp interrupted(status, %Run{approval_commit: run_approval} = latest, approval)
       when status in [:approved, :building, :failed] and run_approval in [nil, approval] do
    case StateView.interrupted?(latest) do
      {:ok, true} -> :interrupted
      _not_interrupted -> status
    end
  end

  defp interrupted(status, _latest, _approval), do: status

  defp claimed_run?(%Run{id: claim_run_id}, claim_run_id) when is_binary(claim_run_id), do: true
  defp claimed_run?(_latest, _claim_run_id), do: false

  defp terminal_for_approval?(
         %Run{approval_commit: run_approval, status: run_status},
         approval,
         status
       )
       when is_binary(approval) and run_approval == approval and run_status == status and
              status in [:failed, :parked], do: true

  defp terminal_for_approval?(_latest, _approval, _status), do: false

  # Failed and parked Intents show why the Build stopped; a building one shows its stage.
  defp detail(status, %Run{} = run) when status in [:failed, :parked, :interrupted, :building] do
    case StateView.events(run) do
      {:ok, events} -> event_detail(status, events)
      {:error, reason} -> "journal unreadable (#{inspect(reason)})"
    end
  end

  defp detail(_status, _run), do: nil

  defp event_detail(:building, events) do
    events
    |> Enum.reverse()
    |> Enum.find_value("starting", fn
      %Event{event: "phase_timing", name: name} when is_binary(name) -> name
      %Event{stage: stage} when is_binary(stage) -> stage
      _event -> nil
    end)
  end

  defp event_detail(_status, events), do: BuildSummary.reason(events)

  defp started_at(:building, %Run{dir: dir}) do
    case File.stat(Path.join(dir, "run.json"), time: :posix) do
      {:ok, stat} -> stat.mtime
      {:error, :enoent} -> nil
    end
  end

  defp started_at(_status, _run), do: nil

  defp valid_slug?(slug), do: Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)
end
