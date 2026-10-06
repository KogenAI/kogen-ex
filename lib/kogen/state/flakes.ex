defmodule Kogen.State.Flakes do
  @moduledoc false
  alias Kogen.State.Flakes.Codec
  alias Kogen.State.Flakes.Drafts
  alias Kogen.State.Json
  alias Kogen.State.RunStore

  @spec record(struct(), map()) :: :ok | {:error, term()}
  def record(run, event) do
    with :ok <- RunStore.record(run, event) do
      {observations, notes} = history(Path.dirname(run.dir))
      metrics = metrics(observations, notes)

      with :ok <- RunStore.record(run, %{event: :flake_metrics, metrics: metrics}),
           do: draft(run, observations)
    end
  end

  defp draft(run, observations) do
    case Drafts.update(run, observations) do
      :ok ->
        :ok

      {:error, reason} ->
        RunStore.record(run, %{
          event: :flake_fix_failed,
          reason: inspect(reason),
          detail:
            "Fix draft could not be written; caller action required. Build completion policy is unchanged."
        })
    end
  end

  defp history(runs) do
    runs
    |> Path.join("*/events.jsonl")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce({[], []}, fn file, acc ->
      case File.read(file) do
        {:ok, bytes} -> read_lines(file, bytes, acc)
        {:error, reason} -> {elem(acc, 0), [{file, inspect(reason)} | elem(acc, 1)]}
      end
    end)
  end

  defp read_lines(file, bytes, acc) do
    run_id = file |> Path.dirname() |> Path.basename()

    bytes
    |> String.split("\n", trim: true)
    |> Enum.reduce(acc, fn line, {observations, notes} ->
      case Json.decode_event(line) do
        {:ok, %{event: kind} = event} when kind in ["flake_classified", "flake_excused"] ->
          {[Codec.observation(run_id, event) | observations], notes}

        {:ok, _other} ->
          {observations, notes}

        {:error, reason} ->
          {observations, [{file, inspect(reason)} | notes]}
      end
    end)
  end

  defp metrics(observations, notes) do
    classified = Enum.filter(observations, &(&1.kind == "flake_classified"))
    receipts = Enum.filter(observations, &(&1.kind == "flake_excused"))
    base = Enum.filter(receipts, &(&1.classification == "base_flake"))

    recurrence =
      for {id, records} <- Drafts.group(base),
          do: %{test_id: id, builds: length(Enum.uniq_by(records, & &1.run_id))}

    %{
      scope: "project state history",
      history_complete: notes == [],
      history_notes: Enum.map(notes, fn {file, reason} -> %{path: file, reason: reason} end),
      classified: length(classified),
      candidate_flakes:
        Enum.count(
          classified,
          &(&1.classification in ["candidate_flake", "base_flake"] and &1.candidate_ids != [])
        ),
      unconfirmed_flakes: Enum.count(classified, &(&1.classification == "unconfirmed_flake")),
      excused_base_flakes: length(base),
      leaked_candidate_flakes:
        receipts
        |> Enum.reject(&(&1.classification == "legacy_unknown"))
        |> Enum.flat_map(&(&1.excused -- &1.base_ids))
        |> length(),
      legacy_excusal_without_evidence:
        Enum.count(receipts, &(&1.classification == "legacy_unknown")),
      retry_cost_ms: Enum.sum(Enum.map(classified, & &1.cost_ms)),
      recurrence: recurrence,
      policy:
        "existing two-test excusal cap is provisional; no queue-stop rate selected; started Builds finish under existing completion rulings"
    }
  end
end
