defmodule Kogen.Queue.BuildSummary do
  @moduledoc """
  The latest Build of an Intent in a few fields for `kogen status <slug>`: its outcome and
  reason, model time per stage, the last candidate diff and the journal directory.
  """

  alias Kogen.Contracts.GateTiming.Codec
  alias Kogen.Queue.StateView
  alias Kogen.State.Event
  alias Kogen.State.Run

  @enforce_keys [:build_id, :run_status, :journal]
  defstruct @enforce_keys ++
              [
                reason: nil,
                stages: [],
                candidate_diff: nil,
                continuations: 0,
                progress: nil,
                gate_timing: nil
              ]

  @type t :: %__MODULE__{
          build_id: String.t(),
          run_status: Run.status(),
          journal: Path.t(),
          reason: String.t() | nil,
          stages: [{String.t(), non_neg_integer()}],
          gate_timing: Kogen.Contracts.GateTiming.t() | nil,
          progress: map() | nil,
          candidate_diff: Path.t() | nil,
          continuations: non_neg_integer()
        }

  @spec latest(Path.t(), String.t()) :: {:ok, t() | nil} | {:error, term()}
  def latest(state_root, slug) do
    with {:ok, runs} <- StateView.runs(state_root, slug),
         {:ok, run} <- StateView.latest(runs) do
      case run do
        nil -> {:ok, nil}
        %Run{} -> summarize(run)
      end
    end
  end

  defp summarize(run) do
    with {:ok, events} <- StateView.events(run) do
      {:ok,
       %__MODULE__{
         build_id: run.id,
         run_status: run.status,
         journal: run.dir,
         reason: reason(events),
         stages: stages(events),
         continuations: Enum.count(events, &(&1.event == "context_continued")),
         gate_timing: Codec.latest(events),
         progress: Kogen.Queue.Progress.from_events(events),
         candidate_diff: candidate_diff(run, events)
       }}
    end
  end

  @doc false
  @spec reason([Event.t()]) :: String.t() | nil
  def reason(events) do
    reversed = Enum.reverse(events)

    Enum.find_value(reversed, fn
      %Event{event: "shaping_stale", detail: detail} when is_binary(detail) ->
        "shaping_stale: #{detail}"

      %Event{event: "best_candidate", branch: branch} when is_binary(branch) ->
        "needs attention: #{branch}"

      _event ->
        nil
    end) ||
      Enum.find_value(reversed, fn
        %Event{event: "finished", reason: reason} when is_binary(reason) -> reason
        _event -> nil
      end) ||
      Enum.find_value(reversed, fn
        %Event{event: "stage_failure", class: class, reason: reason}
        when is_binary(class) and is_binary(reason) ->
          "#{class}/#{reason}"

        _event ->
          nil
      end)
  end

  defp stages(events) do
    Enum.reduce(events, [], fn
      %Event{event: "model_stage", stage: stage, wall_ms: wall}, totals when is_binary(stage) ->
        {_stage, sum} = List.keyfind(totals, stage, 0, {stage, 0})
        List.keystore(totals, stage, 0, {stage, sum + (wall || 0)})

      _event, totals ->
        totals
    end)
  end

  defp candidate_diff(run, events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Event{event: "candidate_diff", candidate_diff: file} when is_binary(file) ->
        Path.join(run.dir, file)

      _event ->
        nil
    end)
  end
end
