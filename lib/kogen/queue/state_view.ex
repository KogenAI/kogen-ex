defmodule Kogen.Queue.StateView do
  @moduledoc "Reads Build run journals: runs per Intent, the latest run and its events."

  alias Kogen.Queue.Liveness
  alias Kogen.State
  alias Kogen.State.Event
  alias Kogen.State.Run

  @spec runs(Path.t(), String.t()) :: {:ok, [Run.t()]} | {:error, term()}
  def runs(state_root, slug) do
    with {:ok, all_runs} <- State.list(state_root) do
      {:ok, Enum.filter(all_runs, &(&1.slug == slug))}
    end
  end

  @doc "Records a SIGTERM interruption on every running Build this OS process owns."
  @spec interrupt(Path.t(), pos_integer()) :: :ok | {:error, term()}
  def interrupt(state_root, owner_os_pid) do
    with {:ok, all_runs} <- State.list(state_root) do
      all_runs
      |> Enum.filter(&(&1.status == :running and &1.owner_os_pid == owner_os_pid))
      |> Enum.reduce_while(:ok, fn run, :ok ->
        case State.record(run, %{event: :interrupted, reason: :sigterm}) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
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

  @doc """
  A Build ended by SIGTERM: still running with `interrupted` as its last event and a dead
  owner, or already closed by recovery with reason `interrupted`.
  """
  @spec interrupted?(Run.t() | nil) :: {:ok, boolean()} | {:error, term()}
  def interrupted?(%Run{status: status} = run) when status in [:running, :failed] do
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
        case Liveness.alive?(run.owner_os_pid, run.dir) do
          {:ok, alive?} -> {:ok, not alive?}
          {:error, reason} -> {:error, reason}
        end

      _event ->
        {:ok, false}
    end
  end

  def interrupted?(%Run{status: :failed}, run_events) when is_list(run_events) do
    {:ok, match?(%Event{event: "finished", reason: "interrupted"}, List.last(run_events))}
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
