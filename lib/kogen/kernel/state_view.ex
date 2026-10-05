defmodule Kogen.Kernel.StateView do
  @moduledoc false

  alias Kogen.State
  alias Kogen.State.Event
  alias Kogen.State.Run

  @spec runs(Path.t(), String.t()) :: {:ok, [Run.t()]} | {:error, term()}
  def runs(state_root, slug) do
    with {:ok, all_runs} <- State.list(state_root) do
      {:ok, Enum.filter(all_runs, &(&1.slug == slug))}
    end
  end

  @spec interrupt(Path.t(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def interrupt(state_root, slug, owner_os_pid) do
    with {:ok, matching_runs} <- runs(state_root, slug),
         active_runs =
           Enum.filter(
             matching_runs,
             &(&1.status == :running and &1.owner_os_pid == owner_os_pid)
           ),
         {:ok, latest} <- latest(active_runs) do
      case latest do
        %Run{} = run -> State.record(run, %{event: :interrupted, reason: :sigterm})
        nil -> :ok
      end
    end
  end

  @spec preferred_root(Path.t(), Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def preferred_root(current_root, legacy_root, slug) do
    with {:ok, current_runs} <- runs(current_root, slug),
         {:ok, legacy_runs} <- runs(legacy_root, slug) do
      cond do
        current_runs != [] -> {:ok, current_root}
        legacy_runs != [] -> {:ok, legacy_root}
        true -> {:ok, current_root}
      end
    end
  end

  @spec latest([Run.t()]) :: {:ok, Run.t() | nil} | {:error, term()}
  def latest([]), do: {:ok, nil}

  def latest(runs) do
    runs
    |> Enum.reduce_while({:ok, []}, fn run, {:ok, dated} ->
      case run_timestamp(run) do
        {:ok, timestamp} -> {:cont, {:ok, [{timestamp, run} | dated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, dated} -> {:ok, dated |> Enum.max_by(&elem(&1, 0)) |> elem(1)}
      error -> error
    end
  end

  @spec events(Run.t()) :: {:ok, [Event.t()]} | {:error, term()}
  def events(%Run{} = run) do
    path = Path.join(run.dir, "events.jsonl")

    case File.read(path) do
      {:ok, contents} -> decode_events(contents)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec interrupted?(Run.t() | nil) :: {:ok, boolean()} | {:error, term()}
  def interrupted?(%Run{status: :running} = run) do
    case events(run) do
      {:ok, run_events} -> interrupted?(run, run_events)
      {:error, :enoent} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  def interrupted?(other) when is_nil(other) or is_struct(other, Run), do: {:ok, false}

  @spec interrupted?(Run.t(), [Event.t()]) :: {:ok, boolean()} | {:error, term()}
  def interrupted?(%Run{status: :running} = run, run_events) when is_list(run_events) do
    case List.last(run_events) do
      %Event{event: "interrupted"} ->
        case Kogen.Kernel.Reconcile.owner_alive?(run.owner_os_pid, run.dir) do
          {:ok, alive?} -> {:ok, not alive?}
          {:error, reason} -> {:error, reason}
        end

      _event ->
        {:ok, false}
    end
  end

  def interrupted?(%Run{}, _run_events), do: {:ok, false}

  defp run_timestamp(%Run{} = run) do
    case File.stat(Path.join(run.dir, "run.json")) do
      {:ok, stat} -> {:ok, :calendar.datetime_to_gregorian_seconds(stat.mtime)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_events(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, events} ->
      case State.decode_event(line) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :invalid_event}
  end
end

defmodule Kogen.Kernel.Status do
  @moduledoc false

  alias Kogen.Kernel.StateView
  alias Kogen.Kernel.Types.IntentStatus
  alias Kogen.State
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
           ) do
      run_rows = latest_runs(slugs, current_runs, legacy_runs)
      render_statuses(slugs, run_rows, snapshot)
    end
  rescue
    ArgumentError -> {:error, :status_unavailable}
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

  defp render_statuses(slugs, {:ok, latest_runs}, snapshot) do
    slugs
    |> Enum.reduce_while({:ok, []}, fn slug, {:ok, statuses} ->
      latest = Map.get(latest_runs, slug)
      approval = Map.get(snapshot.approvals, slug)
      landed_sha = Map.get(snapshot.landed, slug)

      case StateView.interrupted?(latest) do
        {:ok, interrupted?} ->
          status =
            if interrupted?,
              do: :interrupted,
              else: lifecycle_status(slug, approval, landed_sha, latest, snapshot.claim_run_id)

          row = %IntentStatus{
            slug: slug,
            status: status,
            run_id: if(match?(%Run{}, latest), do: latest.id),
            landed_sha: landed_sha
          }

          {:cont, {:ok, [row | statuses]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, statuses} -> {:ok, Enum.reverse(statuses)}
      error -> error
    end
  end

  defp render_statuses(_slugs, error, _snapshot), do: error

  defp lifecycle_status(_slug, _approval, landed_sha, _latest, _claim_run_id)
       when is_binary(landed_sha), do: :landed

  defp lifecycle_status(slug, approval, nil, latest, claim_run_id) do
    cond do
      claimed_run?(slug, latest, claim_run_id) -> :building
      terminal_for_approval?(latest, approval, :parked) -> :parked
      terminal_for_approval?(latest, approval, :failed) -> :failed
      is_binary(approval) -> :approved
      true -> :draft
    end
  end

  defp claimed_run?(_slug, %Run{id: claim_run_id}, claim_run_id) when is_binary(claim_run_id),
    do: true

  defp claimed_run?(_slug, _latest, _claim_run_id), do: false

  defp terminal_for_approval?(
         %Run{approval_commit: run_approval, status: run_status},
         approval,
         status
       )
       when is_binary(approval) and run_approval == approval and run_status == status and
              status in [:failed, :parked], do: true

  defp terminal_for_approval?(_latest, _approval, _status), do: false

  defp valid_slug?(slug), do: Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)
end

defmodule Kogen.Kernel.Reconcile do
  @moduledoc false

  alias Kogen.Proc
  alias Kogen.State
  alias Kogen.Workspace

  @pid_liveness_script """
  use Errno qw(ESRCH EPERM);
  my $pid = shift @ARGV;
  local $! = 0;
  my $found = kill(0, $pid);
  exit 0 if $found;
  exit 1 if $! == ESRCH;
  exit 0 if $! == EPERM;
  exit 2;
  """

  @spec run(String.t(), Path.t(), Path.t(), Path.t(), String.t(), map()) ::
          {:ok, :crashed | :landed | :unchanged} | {:error, term()}
  def run(run_id, project_root, workspace_root, origin, base, git_env) do
    legacy_root = Path.join(project_root, ".kogen")

    with {:ok, run, state_root} <- load_run(workspace_root, legacy_root, run_id) do
      case run.status do
        :running ->
          reconcile_unfinished(
            run,
            state_root,
            existing_workspace(legacy_root, workspace_root, run.id),
            origin,
            base,
            git_env
          )

        _terminal ->
          State.reconcile(origin, state_root, run, base, git_env)
      end
    end
  end

  defp load_run(current_root, legacy_root, run_id) do
    case State.load(current_root, run_id) do
      {:ok, run} -> {:ok, run, current_root}
      {:error, :enoent} -> load_legacy_run(legacy_root, run_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_legacy_run(legacy_root, run_id) do
    case State.load(legacy_root, run_id) do
      {:ok, run} -> {:ok, run, legacy_root}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_unfinished(run, state_root, workspace, origin, base, git_env) do
    case owner_alive?(run.owner_os_pid, run.dir) do
      {:ok, true} ->
        {:ok, :unchanged}

      {:ok, false} ->
        case State.reconcile(origin, state_root, run, base, git_env) do
          {:ok, :landed} ->
            with :ok <- Workspace.destroy(workspace), do: {:ok, :landed}

          {:ok, :unchanged} ->
            with :ok <- State.recover_crashed(origin, state_root, run, git_env),
                 :ok <- Workspace.destroy(workspace) do
              {:ok, :crashed}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_workspace(legacy_root, workspace_root, run_id) do
    current = Path.join(workspace_root, run_id)
    legacy = Path.join([legacy_root, "w", run_id])
    if File.dir?(current), do: current, else: legacy
  end

  @doc false
  @spec owner_alive?(pos_integer() | nil, Path.t()) :: {:ok, boolean()} | {:error, term()}
  def owner_alive?(pid, directory) when is_integer(pid) and pid > 0 do
    case Proc.run(
           ["/usr/bin/perl", "-e", @pid_liveness_script, Integer.to_string(pid)],
           cd: directory
         ) do
      {:ok, %{exit_status: 0}} ->
        {:ok, true}

      {:ok, %{exit_status: 1}} ->
        {:ok, false}

      {:ok, %{exit_status: status, output_tail: output}} ->
        {:error, {:owner_liveness_check_failed, status, output}}

      {:error, reason} ->
        {:error, {:owner_liveness_check_failed, reason}}
    end
  end

  def owner_alive?(_pid, _directory), do: {:ok, false}
end
