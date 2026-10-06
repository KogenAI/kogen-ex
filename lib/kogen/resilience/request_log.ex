defmodule Kogen.Resilience.RequestLog do
  @moduledoc """
  One run-journal record per model request, written whatever its outcome.

  A request is one provider call: a retried request leaves one record per attempt, and
  `retries` counts the attempts before it. Times are epoch milliseconds; `first_byte_at` and
  `last_byte_at` bound the response's progress and are null when the provider never answered
  (or cannot tell). A `stall` record's `idle_ms` is the silence that ended it. Token counts are
  null unless the response reported them. The journal file is `requests.jsonl` in the run
  directory. `cut_after_ms` records how long an interrupted stream ran; `resumed` means
  the attempt carries received conversation from an earlier interrupted attempt.
  """

  alias Kogen.Contracts.ModelRequest
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
          optional(:resumed) => boolean(),
          required(:stage) => atom(),
          required(:turn) => non_neg_integer(),
          required(:model) => String.t(),
          required(:effort) => String.t(),
          required(:retries) => non_neg_integer(),
          required(:history) => %{
            items: non_neg_integer(),
            bytes: non_neg_integer(),
            tool_output_bytes: non_neg_integer()
          },
          required(:tags) => map(),
          optional(:request_shape) => map()
        }

  @spec settings(ModelRequest.t(), term()) :: map()
  def settings(request, provider_config) do
    adapter =
      if request.adapter == :responses and
           is_map(provider_config) and Map.get(provider_config, :source) == :kogen_owned,
         do: :siwc,
         else: request.adapter

    Map.new(
      %{
        adapter: adapter,
        adapter_version: "codex-0.160.0/kogen-1",
        text_verbosity: request.text_verbosity,
        reasoning_summary: request.reasoning_summary,
        reasoning_context: request.reasoning_context,
        tool_choice: request.tool_choice,
        parallel_tool_calls: request.parallel_tool_calls,
        session_id: request.session_id,
        model_generation_tokens: request.model_generation_tokens
      },
      fn {key, value} -> {key, if(is_nil(value), do: :null, else: value)} end
    )
  end

  @doc "Starts timing one request."
  @spec start() :: t()
  def start, do: %__MODULE__{started_at: now(), progress: :atomics.new(2, signed: false)}

  @doc "Marks the first body byte, including comments and keepalives."
  @spec first_byte_marker(t()) :: (-> :ok)
  def first_byte_marker(%__MODULE__{progress: ref}) do
    fn ->
      at = now()
      _previous = :atomics.compare_exchange(ref, 1, 0, at)
      _previous = :atomics.compare_exchange(ref, 2, 0, at)
      :ok
    end
  end

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

    Map.merge(
      %{
        record_kind: :model_request,
        stage: meta.stage,
        conversation_id: nullable(Map.get(meta.tags, :conversation_id)),
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
        resumed: Map.get(meta, :resumed, false),
        cut_after_ms: cut_after_ms(result),
        response_id: response_id(result),
        incomplete_reason: incomplete_reason(result),
        usage_status: usage_status(tokens, outcome),
        idle_ms: idle_ms(outcome, last_byte_at, ended_at),
        retries: meta.retries,
        tokens: tokens,
        history_items: meta.history.items,
        history_bytes: meta.history.bytes,
        tool_output_bytes: meta.history.tool_output_bytes,
        request_settings: Map.get(meta, :settings, %{})
      },
      Map.get(meta, :request_shape, %{})
    )
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

  defp cut_after_ms({:error, %ProviderError{cut_after_ms: cut}}), do: cut || :null
  defp cut_after_ms(_result), do: :null

  defp outcome({:ok, %ModelResponse{usage: usage}}), do: {:ok, tokens(usage)}
  defp outcome({:error, %ProviderError{class: class, usage: usage}}), do: {class, tokens(usage)}

  defp tokens(usage) when is_map(usage) and map_size(usage) > 0 do
    Map.new(@token_names, fn name -> {name, count(Map.get(usage, name))} end)
  end

  defp tokens(_usage), do: :null

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: :null

  defp response_id({:ok, response}), do: response.id
  defp response_id({:error, error}), do: error.response_id || :null
  defp incomplete_reason({:ok, _response}), do: :null
  defp incomplete_reason({:error, error}), do: error.incomplete_reason || :null
  defp usage_status(:null, _outcome), do: :unknown
  defp usage_status(_tokens, :incomplete), do: :partial

  defp usage_status(tokens, _outcome) do
    if Enum.all?([:input, :cached_input, :output, :reasoning], &is_integer(Map.get(tokens, &1))),
      do: :reported,
      else: :partial
  end

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
