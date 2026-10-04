defmodule Kogen.Harness.Exchange.Request do
  @moduledoc false

  @enforce_keys [
    :stage,
    :turn,
    :model,
    :effort,
    :instructions,
    :items,
    :tool_names,
    :remaining_ms
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          stage: atom(),
          turn: non_neg_integer(),
          model: String.t(),
          effort: String.t(),
          instructions: String.t(),
          items: [map()],
          tool_names: [Kogen.Harness.Codec.tool_name()],
          remaining_ms: non_neg_integer()
        }
end

defmodule Kogen.Harness.Exchange do
  @moduledoc false

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Exchange.Request
  alias Kogen.Harness.Opts
  alias Kogen.Harness.PromptCacheKey
  alias Kogen.Harness.Recording

  @retry_backoff_ms 200

  @spec respond(Opts.t(), Request.t()) :: {:ok, ModelResponse.t()} | {:error, term()}
  def respond(%Opts{} = opts, %Request{} = exchange_request) do
    request = build_request(opts, exchange_request)

    with :ok <-
           Recording.append(
             opts,
             :request,
             exchange_request.stage,
             exchange_request.turn,
             request
           ) do
      deadline = System.monotonic_time(:millisecond) + exchange_request.remaining_ms
      result = provider_call(opts, request, exchange_request.remaining_ms)
      respond_after_first_attempt(opts, exchange_request, request, deadline, result)
    end
  end

  defp respond_after_first_attempt(
         opts,
         exchange_request,
         request,
         deadline,
         {:error, %ProviderError{class: class} = error}
       )
       when class in [:timeout, :transport] do
    if remaining_ms(deadline) > @retry_backoff_ms do
      retry_after_transient_error(opts, exchange_request, request, deadline, error)
    else
      record_response(opts, exchange_request, {:error, error})
    end
  end

  defp respond_after_first_attempt(opts, exchange_request, _request, _deadline, result),
    do: record_response(opts, exchange_request, result)

  defp retry_after_transient_error(opts, exchange_request, request, deadline, error) do
    retry_event = %{
      event: :provider_retry,
      stage: exchange_request.stage,
      turn: exchange_request.turn,
      attempt: 1,
      reason: error.class,
      detail: "Retrying idempotent model request once after #{error.class}."
    }

    with :ok <-
           Recording.append(
             opts,
             :provider_error,
             exchange_request.stage,
             exchange_request.turn,
             error
           ),
         :ok <- record_event(opts, exchange_request, retry_event) do
      receive do
      after
        @retry_backoff_ms -> :ok
      end

      with :ok <-
             Recording.append(
               opts,
               :request,
               exchange_request.stage,
               exchange_request.turn,
               request
             ) do
        result = provider_call(opts, request, remaining_ms(deadline))
        record_response(opts, exchange_request, result)
      end
    end
  end

  defp record_event(%Opts{event_recorder: nil} = opts, request, event) do
    Recording.append(opts, event.event, request.stage, request.turn, event)
  end

  defp record_event(%Opts{event_recorder: recorder} = opts, request, event)
       when is_function(recorder, 1) do
    with :ok <-
           Recording.append(
             opts,
             event.event,
             request.stage,
             request.turn,
             event
           ) do
      recorder.(event)
    end
  end

  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp build_request(opts, request) do
    %{
      Codec.request(
        request.model,
        request.effort,
        request.instructions,
        request.items,
        request.tool_names
      )
      | prompt_cache_key: PromptCacheKey.for_run_stage(opts.run_dir, request.stage)
    }
  end

  defp provider_call(_opts, _request, remaining_ms) when remaining_ms <= 0, do: timeout_error()

  defp provider_call(opts, %ModelRequest{} = request, remaining_ms) do
    caller = self()
    result_ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        send(caller, {result_ref, opts.provider_mod.respond(opts.provider_config, request)})
      end)

    await_provider(result_ref, worker, monitor, remaining_ms)
  end

  defp await_provider(result_ref, worker, monitor, remaining_ms) do
    receive do
      {^result_ref, {:ok, %ModelResponse{} = response}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, response}

      {^result_ref, {:error, %ProviderError{} = error}} ->
        Process.demonitor(monitor, [:flush])
        {:error, error}

      {^result_ref, _invalid} ->
        Process.demonitor(monitor, [:flush])
        provider_error(:malformed, "Provider returned an invalid response.")

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        provider_error(:transport, "Provider process failed: #{inspect(reason)}")
    after
      remaining_ms ->
        stop_worker(worker, monitor)
        timeout_error()
    end
  end

  defp stop_worker(worker, monitor) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      0 -> Process.demonitor(monitor, [:flush])
    end
  end

  defp record_response(opts, request, {:ok, %ModelResponse{} = response}) do
    with :ok <-
           Recording.append(opts, :response, request.stage, request.turn, response) do
      {:ok, response}
    end
  end

  defp record_response(opts, request, {:error, %ProviderError{} = error}) do
    with :ok <-
           Recording.append(opts, :provider_error, request.stage, request.turn, error) do
      {:error, error}
    end
  end

  defp timeout_error,
    do: provider_error(:timeout, "Harness wall deadline reached during provider request.")

  defp provider_error(class, message),
    do: {:error, %ProviderError{class: class, message: message}}
end
