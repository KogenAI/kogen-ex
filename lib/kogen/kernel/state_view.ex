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
    project_root
    |> intent_paths()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, statuses} ->
      slug = path |> Path.dirname() |> Path.basename()

      case intent_status(project_root, origin, state_root, slug, base, git_env) do
        {:ok, status} -> {:cont, {:ok, [status | statuses]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, statuses} -> {:ok, Enum.reverse(statuses)}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :status_unavailable}
  end

  defp intent_paths(project_root) do
    [project_root, ".kogen", "intents", "*", "intent.md"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&valid_slug?(Path.basename(Path.dirname(&1))))
    |> Enum.sort()
  end

  defp intent_status(project_root, origin, state_root, slug, base, git_env) do
    legacy_root = Path.join(project_root, ".kogen")

    with {:ok, selected_root} <- StateView.preferred_root(state_root, legacy_root, slug) do
      load_intent_status(origin, selected_root, slug, base, git_env)
    end
  end

  defp load_intent_status(origin, state_root, slug, base, git_env) do
    status = State.status(origin, state_root, slug, base, git_env)

    with {:ok, runs} <- StateView.runs(state_root, slug),
         {:ok, latest} <- StateView.latest(runs),
         {:ok, landed_sha} <- landed_sha(status, origin, base, slug, runs, git_env) do
      {:ok,
       %IntentStatus{
         slug: slug,
         status: status,
         run_id: if(match?(%Run{}, latest), do: latest.id),
         landed_sha: landed_sha
       }}
    end
  end

  defp landed_sha(:landed, origin, base, slug, _runs, git_env),
    do: Workspace.intent_commit(origin, base, slug, git_env)

  defp landed_sha(_status, _origin, _base, _slug, _runs, _git_env), do: {:ok, nil}

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

  defp owner_alive?(pid, directory) when is_integer(pid) and pid > 0 do
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

  defp owner_alive?(_pid, _directory), do: {:ok, false}
end

defmodule Kogen.Kernel.Report do
  @moduledoc false

  alias Kogen.Kernel.StateView
  alias Kogen.State.Event
  alias Kogen.State.Run
  alias Kogen.Workspace

  @spec read(String.t(), Path.t(), Path.t(), String.t(), map()) ::
          {:ok, binary()} | {:error, term()}
  def read(slug, state_root, origin, base, git_env) do
    with {:ok, runs} <- StateView.runs(state_root, slug),
         {:ok, %Run{} = run} <- StateView.latest(runs),
         {:ok, events} <- StateView.events(run),
         {:ok, landed_sha} <- landed_sha(run, origin, base, git_env) do
      encode(run, events, landed_sha)
    else
      {:ok, nil} -> {:error, :missing_run}
      error -> error
    end
  end

  defp landed_sha(%Run{landing: nil}, _origin, _base, _git_env), do: {:ok, nil}

  defp landed_sha(%Run{landing: landing}, origin, base, git_env) do
    with {:ok, branch_sha} <- Workspace.rev_parse(origin, "refs/heads/#{base}", git_env) do
      if Workspace.ancestor?(origin, landing.candidate_commit, branch_sha, git_env),
        do: {:ok, landing.candidate_commit},
        else: {:ok, nil}
    end
  end

  defp encode(%Run{} = run, events, landed_sha) do
    report =
      json_object([
        {"slug", run.slug},
        {"status", Atom.to_string(run.status)},
        {"recipe", nullable(event_value(events, :recipe))},
        {"approval", nullable(run.approval_commit)},
        {"base",
         nullable(event_value(events, :base_sha) || landing_value(run, :expected_parent))},
        {"candidate", nullable(landing_value(run, :candidate_commit))},
        {"landed_sha", nullable(landed_sha)},
        {"credential",
         json_object([
           {"source", nullable(event_value(events, :credential_source))},
           {"label", nullable(event_value(events, :credential_label))}
         ])},
        {"acceptance_results", event_payload(events, "acceptance_result", :ledger, [])},
        {"check_receipts", event_payload(events, "check_result", :receipts, [])},
        {"excused_flakes", excused_flakes(events)},
        {"model_stages", model_stages(events)},
        {"findings", findings(events)},
        {"failures", failures(events)}
      ])

    {:ok, report |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    ArgumentError -> {:error, :report_encoding_failed}
  end

  defp model_stages(events) do
    for %Event{event: "model_stage"} = event <- events do
      json_object([
        {"stage", event.stage},
        {"model", event.model},
        {"effort", event.effort},
        {"tokens", event.tokens},
        {"wall_ms", event.wall_ms}
      ])
    end
  end

  defp failures(events) do
    for %Event{event: "stage_failure"} = event <- events do
      json_object([
        {"stage", event.stage},
        {"class", event.class},
        {"reason", event.reason},
        {"detail", event.detail}
      ])
    end
  end

  defp findings(events) do
    for %Event{event: "scope_warning"} = event <- events do
      json_object([
        {"type", "scope_warning"},
        {"path", event.path},
        {"declared_domains", event.declared_domains},
        {"message", event.detail}
      ])
    end
  end

  defp excused_flakes(events) do
    for %Event{event: "flake_excused"} = event <- events do
      json_object([{"test_ids", event.test_ids}, {"seed", event.seed}])
    end
  end

  defp event_value(events, key) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&Map.get(&1, key))
  end

  defp event_payload(events, event_name, key, default) do
    events
    |> Enum.reverse()
    |> Enum.find_value(default, fn
      %Event{event: ^event_name} = event -> Map.get(event, key)
      _other -> nil
    end)
  end

  defp landing_value(%Run{landing: nil}, _key), do: nil
  defp landing_value(%Run{landing: landing}, :expected_parent), do: landing.expected_parent
  defp landing_value(%Run{landing: landing}, :candidate_commit), do: landing.candidate_commit

  defp json_object(pairs), do: Map.new(pairs)

  defp nullable(nil), do: :null
  defp nullable(value), do: value
end
