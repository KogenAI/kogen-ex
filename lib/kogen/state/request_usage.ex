defmodule Kogen.State.RequestUsage do
  @moduledoc """
  Model usage that the request journal (`requests.jsonl`) saw but no finished stage recorded:
  requests of a stage that failed, was cut off or was repeated. It is the difference between
  what the journal says each stage's requests used and what its `model_stage` events say, so a
  failed request or a stopped Build no longer drops the usage already spent.
  """

  alias Kogen.State.Event
  alias Kogen.State.Json
  alias Kogen.State.Run

  @token_names ["input", "cached_input", "output", "reasoning"]

  @doc "Synthetic `model_stage` events (`partial: true`, zero wall time) for the unrecorded usage."
  @spec unfinished(Run.t(), [Event.t()]) :: {:ok, [Event.t()]} | {:error, term()}
  def unfinished(%Run{dir: dir}, events) do
    with {:ok, requests} <- requests(dir) do
      recorded = recorded(events)

      partial =
        requests
        |> Enum.group_by(&key/1)
        |> Enum.flat_map(fn {{attempt, stage}, rows} ->
          tokens = difference(sum(rows), Map.get(recorded, {attempt, stage}, %{}))
          partial_event(attempt, stage, List.last(rows), tokens)
        end)
        |> Enum.sort_by(&{&1.attempt, &1.stage})

      {:ok, partial}
    end
  end

  defp partial_event(attempt, stage, %Event{} = last, tokens) do
    if Enum.all?(tokens, fn {_name, count} -> count == 0 end) do
      []
    else
      [
        %Event{
          event: "model_stage",
          stage: stage,
          attempt: attempt,
          model: last.model,
          effort: last.effort,
          tokens: tokens,
          wall_ms: 0,
          partial: true
        }
      ]
    end
  end

  defp recorded(events) do
    events
    |> Enum.filter(&(&1.event == "model_stage"))
    |> Enum.group_by(&key/1)
    |> Map.new(fn {key, rows} -> {key, sum(rows)} end)
  end

  defp key(%Event{} = event), do: {event.attempt || "builder", event.stage}

  defp requests(dir) do
    case File.read(Path.join(dir, "requests.jsonl")) do
      {:ok, contents} ->
        rows =
          for line <- String.split(contents, "\n", trim: true),
              {:ok, %Event{} = row} <- [Json.decode_request(line)],
              do: row

        {:ok, rows}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:requests_unreadable, reason}}
    end
  end

  defp sum(rows) do
    Map.new(@token_names, fn name ->
      {name, Enum.reduce(rows, 0, &(count(&1.tokens, name) + &2))}
    end)
  end

  defp difference(spent, recorded),
    do: Map.new(@token_names, &{&1, max(spent[&1] - Map.get(recorded, &1, 0), 0)})

  defp count(tokens, name) when is_map(tokens) do
    case Map.get(tokens, name) do
      value when is_integer(value) -> value
      _missing -> 0
    end
  end

  defp count(_tokens, _name), do: 0
end
