defmodule Kogen.Queue.Recovery do
  @moduledoc """
  Automatic crash recovery. A running Build whose owner process is dead is closed as landed
  when its commit is on the branch, otherwise as failed with reason `crashed`; its claim is
  released and its checkout deleted. A Build whose last event is a SIGTERM `interrupted`
  closes with reason `interrupted` instead. There is no command for this: `kogen status` and
  `kogen queue start` call `recover/5` first.
  """

  alias Kogen.Queue.Liveness
  alias Kogen.Queue.StateView
  alias Kogen.State
  alias Kogen.Workspace

  @spec recover(Path.t(), Path.t(), Path.t(), String.t(), map()) ::
          {:ok, [{String.t(), :crashed | :landed}]} | {:error, term()}
  def recover(project_root, workspace_root, origin, base, git_env) do
    legacy_root = Path.join(project_root, ".kogen")

    with {:ok, current} <- State.list(workspace_root),
         {:ok, legacy} <- legacy_runs(workspace_root, legacy_root) do
      (current ++ legacy)
      |> Enum.filter(&(&1.status == :running))
      |> Enum.reduce_while({:ok, []}, fn run, {:ok, closed} ->
        case run(run.id, project_root, workspace_root, origin, base, git_env) do
          {:ok, :unchanged} -> {:cont, {:ok, closed}}
          {:ok, outcome} -> {:cont, {:ok, [{run.slug, outcome} | closed]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp legacy_runs(root, root), do: {:ok, []}
  defp legacy_runs(_workspace_root, legacy_root), do: State.list(legacy_root)

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
    case Liveness.alive?(run.owner_os_pid, run.dir) do
      {:ok, true} ->
        {:ok, :unchanged}

      {:ok, false} ->
        case State.reconcile(origin, state_root, run, base, git_env) do
          {:ok, :landed} ->
            with :ok <- Workspace.destroy(workspace), do: {:ok, :landed}

          {:ok, :unchanged} ->
            with {:ok, reason} <- crash_reason(run),
                 :ok <- State.recover_crashed(origin, state_root, run, git_env, reason: reason),
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

  defp crash_reason(run) do
    case StateView.events(run) do
      {:ok, events} ->
        if match?(%{event: "interrupted"}, List.last(events)),
          do: {:ok, :interrupted},
          else: {:ok, :crashed}

      {:error, :enoent} ->
        {:ok, :crashed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_workspace(legacy_root, workspace_root, run_id) do
    current = Path.join(workspace_root, run_id)
    legacy = Path.join([legacy_root, "w", run_id])
    if File.dir?(current), do: current, else: legacy
  end
end
