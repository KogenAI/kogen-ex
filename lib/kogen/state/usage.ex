defmodule Kogen.State.Usage do
  @moduledoc false

  alias Kogen.State.Event
  alias Kogen.State.Json
  alias Kogen.State.Run

  @token_names ["input", "cached_input", "output", "reasoning"]

  @doc "Summed model tokens and model wall time of one Build attempt, from its journal."
  @spec attempt(Run.t(), term()) ::
          {:ok, %{tokens: map(), model_wall_ms: non_neg_integer()}} | {:error, term()}
  def attempt(%Run{dir: dir}, attempt) do
    with {:ok, contents} <- File.read(Path.join(dir, "events.jsonl")) do
      totals(model_rows(contents, to_string(attempt)))
    end
  end

  defp totals(rows) do
    tokens =
      Map.new(@token_names, fn token ->
        {token, Enum.reduce(rows, 0, &(token_count(&1.tokens, token) + &2))}
      end)

    {:ok, %{tokens: tokens, model_wall_ms: Enum.reduce(rows, 0, &((&1.wall_ms || 0) + &2))}}
  end

  defp model_rows(contents, name) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Json.decode_event(line) do
        {:ok, %Event{event: "model_stage"} = event} ->
          if (event.attempt || "builder") == name, do: [event], else: []

        _other ->
          []
      end
    end)
  end

  defp token_count(tokens, name) when is_map(tokens) do
    case Map.get(tokens, name) do
      value when is_integer(value) -> value
      _missing -> 0
    end
  end

  defp token_count(_tokens, _name), do: 0
end
