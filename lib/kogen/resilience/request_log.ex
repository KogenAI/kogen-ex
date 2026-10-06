defmodule Kogen.Resilience.RequestLog do
  @moduledoc """
  One run-journal record per model request, written whatever its outcome.

  A request is one provider call: a retried request leaves one record per attempt, and
  `retries` counts the attempts before it. Times are epoch milliseconds; `first_byte_at` and
  `last_byte_at` bound the response's progress and are null when the provider never answered
  (or cannot tell). A `stall` record's `idle_ms` is the silence that ended it. Token counts are
  null unless the response reported them. The journal file is `requests.jsonl` in the run
  directory.
  """

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Contracts.Redact

  @file_name "requests.jsonl"
  @token_names [:input, :cached_input, :output, :reasoning, :cache_write]

  @enforce_keys [:started_at, :progress]
  defstruct @enforce_keys

  @type t :: %__MODULE__{started_at: integer(), progress: :atomics.atomics_ref()}
  @type meta :: %{
          optional(:settings) => map(),
          stage: atom(),
          turn: non_neg_integer(),
          model: String.t(),
          effort: String.t(),
          retries: non_neg_integer(),
          history: %{
            items: non_neg_integer(),
            bytes: non_neg_integer(),
            tool_output_bytes: non_neg_integer()
          },
          tags: map()
        }

  @doc "Starts timing one request."
  @spec start() :: t()
  def start, do: %__MODULE__{started_at: now(), progress: :atomics.new(2, signed: false)}

  @doc "The request's `on_progress`: the first call marks the first byte, every call the last."
  @spec progress_marker(t()) :: (-> :ok)
  def progress_marker(%__MODULE__{progress: ref}) do
    fn ->
      at = now()
      _previous = :atomics.compare_exchange(ref, 1, 0, at)
      :atomics.put(ref, 2, at)
    end
  end

  @doc "The journal record of a finished request."
  @spec record(t(), meta(), {:ok, ModelResponse.t()} | {:error, ProviderError.t()}) :: map()
  def record(%__MODULE__{} = probe, meta, result) do
    {outcome, tokens} = outcome(result)
    ended_at = now()
    last_byte_at = progress(probe, 2)

    %{
      stage: meta.stage,
      turn: meta.turn,
      attempt: nullable(Map.get(meta.tags, :attempt)),
      rung: nullable(Map.get(meta.tags, :rung)),
      model: meta.model,
      effort: meta.effort,
      started_at: probe.started_at,
      first_byte_at: progress(probe, 1),
      last_byte_at: last_byte_at,
      ended_at: ended_at,
      outcome: outcome,
      idle_ms: idle_ms(outcome, last_byte_at, ended_at),
      retries: meta.retries,
      tokens: tokens,
      history_items: meta.history.items,
      history_bytes: meta.history.bytes,
      tool_output_bytes: meta.history.tool_output_bytes,
      request_settings: Map.get(meta, :settings, %{})
    }
  end

  @doc "Appends `record` to the request journal in `run_dir`."
  @spec append(Path.t(), map()) :: :ok | {:error, term()}
  def append(run_dir, record) do
    with :ok <- File.mkdir_p(run_dir) do
      line = [record |> :json.encode() |> IO.iodata_to_binary() |> Redact.text(), "\n"]
      File.write(Path.join(run_dir, @file_name), line, [:append])
    end
  end

  @doc "The journal's file name inside a run directory."
  @spec file_name() :: String.t()
  def file_name, do: @file_name

  defp outcome({:ok, %ModelResponse{usage: usage}}), do: {:ok, tokens(usage)}
  defp outcome({:error, %ProviderError{class: class}}), do: {class, :null}

  defp tokens(usage) when is_map(usage) and map_size(usage) > 0 do
    Map.new(@token_names, fn name -> {name, count(Map.get(usage, name))} end)
  end

  defp tokens(_usage), do: :null

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: 0

  defp progress(%__MODULE__{progress: ref}, index) do
    case :atomics.get(ref, index) do
      0 -> :null
      at -> at
    end
  end

  defp idle_ms(:stall, last_byte_at, ended_at) when is_integer(last_byte_at),
    do: ended_at - last_byte_at

  defp idle_ms(_outcome, _last_byte_at, _ended_at), do: :null

  defp nullable(nil), do: :null
  defp nullable(value) when is_binary(value) or is_atom(value), do: to_string(value)
  defp nullable(value), do: inspect(value)

  defp now, do: System.system_time(:millisecond)
end
