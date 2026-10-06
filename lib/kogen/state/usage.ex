defmodule Kogen.State.Usage do
  @moduledoc false

  alias Kogen.State.Event
  alias Kogen.State.Json
  alias Kogen.State.RequestUsage
  alias Kogen.State.Run

  @token_names ["input", "cached_input", "output", "reasoning"]

  @doc """
  Summed model tokens and model wall time of one Build attempt, from its journal. Usage of
  requests whose stage failed or was cut off counts too (see `Kogen.State.RequestUsage`).
  """
  @spec attempt(Run.t(), term()) ::
          {:ok, %{tokens: map(), model_wall_ms: non_neg_integer()}} | {:error, term()}
  def attempt(%Run{dir: dir} = run, attempt) do
    with {:ok, contents} <- File.read(Path.join(dir, "events.jsonl")),
         rows = model_rows(contents),
         {:ok, unfinished} <- RequestUsage.unfinished(run, rows) do
      name = to_string(attempt)

      totals(
        Enum.filter(rows, &((&1.attempt || "builder") == name)) ++
          Enum.filter(unfinished, &(&1.attempt == name))
      )
    end
  end

  @doc "Token-weighted cache hit rate; Kogen input counts exclude cached tokens."
  @spec cache_hit_rate([Event.t()]) :: float() | nil
  def cache_hit_rate(events) do
    rows = Enum.filter(events, &(&1.event == "model_stage"))
    input = Enum.reduce(rows, 0, &(token_count(&1.tokens, "input") + &2))
    cached = Enum.reduce(rows, 0, &(token_count(&1.tokens, "cached_input") + &2))
    if input + cached > 0, do: cached / (input + cached)
  end

  defp totals(rows) do
    tokens =
      Map.new(@token_names, fn token ->
        {token, Enum.reduce(rows, 0, &(token_count(&1.tokens, token) + &2))}
      end)

    {:ok, %{tokens: tokens, model_wall_ms: Enum.reduce(rows, 0, &((&1.wall_ms || 0) + &2))}}
  end

  defp model_rows(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Json.decode_event(line) do
        {:ok, %Event{event: "model_stage"} = event} -> [event]
        _other -> []
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
