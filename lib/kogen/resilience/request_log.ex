defmodule Kogen.Resilience.RequestLog do
  @moduledoc """
  One run-journal record per model request, written whatever its outcome.

  A request is one provider call: a retried request leaves one record per attempt, and
  `retries` counts the attempts before it. Times are epoch milliseconds; `first_byte_at` is
  null when the provider never answered (or cannot tell). Token counts are null unless the
  response reported them. The journal file is `requests.jsonl` in the run directory.
  """

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Contracts.Redact

  @file_name "requests.jsonl"
  @token_names [:input, :cached_input, :output, :reasoning, :cache_write]

  @enforce_keys [:started_at, :first_byte]
  defstruct @enforce_keys

  @type t :: %__MODULE__{started_at: integer(), first_byte: :atomics.atomics_ref()}
  @type meta :: %{
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
  def start, do: %__MODULE__{started_at: now(), first_byte: :atomics.new(1, signed: false)}

  @doc "A function the transport calls when the first response byte arrives; only the first call counts."
  @spec first_byte_marker(t()) :: (-> :ok)
  def first_byte_marker(%__MODULE__{first_byte: ref}) do
    fn ->
      _previous = :atomics.compare_exchange(ref, 1, 0, now())
      :ok
    end
  end

  @doc "The journal record of a finished request."
  @spec record(t(), meta(), {:ok, ModelResponse.t()} | {:error, ProviderError.t()}) :: map()
  def record(%__MODULE__{} = probe, meta, result) do
    {outcome, tokens} = outcome(result)

    %{
      stage: meta.stage,
      turn: meta.turn,
      attempt: nullable(Map.get(meta.tags, :attempt)),
      rung: nullable(Map.get(meta.tags, :rung)),
      model: meta.model,
      effort: meta.effort,
      started_at: probe.started_at,
      first_byte_at: first_byte(probe),
      ended_at: now(),
      outcome: outcome,
      retries: meta.retries,
      tokens: tokens,
      history_items: meta.history.items,
      history_bytes: meta.history.bytes,
      tool_output_bytes: meta.history.tool_output_bytes
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

  defp first_byte(%__MODULE__{first_byte: ref}) do
    case :atomics.get(ref, 1) do
      0 -> :null
      at -> at
    end
  end

  defp nullable(nil), do: :null
  defp nullable(value) when is_binary(value) or is_atom(value), do: to_string(value)
  defp nullable(value), do: inspect(value)

  defp now, do: System.system_time(:millisecond)
end
