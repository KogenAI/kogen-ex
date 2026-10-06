defmodule Kogen.Harness.Exchange do
  @moduledoc false

  alias Kogen.Contracts.ExchangeRequest, as: Request
  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Conversation
  alias Kogen.Conversation.PromptCacheKey
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Recording
  alias Kogen.Resilience.Policy
  alias Kogen.Resilience.ProviderCall
  alias Kogen.Resilience.Recovery
  alias Kogen.Resilience.RequestLog
  alias Kogen.Resilience.Retry
  alias Kogen.Tooling.Error

  @spec respond(Opts.t(), Request.t()) :: {:ok, ModelResponse.t()} | {:error, term()}
  def respond(%Opts{} = opts, %Request{} = exchange_request) do
    :ok =
      Kogen.Agents.activity("#{exchange_request.stage} turn #{exchange_request.turn}", :waiting)

    request = build_request(opts, exchange_request)

    with :ok <-
           Recording.append(
             opts,
             :request,
             exchange_request.stage,
             exchange_request.turn,
             request
           ) do
      retry =
        Retry.new(
          Policy.role(exchange_request.stage),
          {exchange_request.model, exchange_request.effort}
        )

      deadline = wall_deadline(exchange_request.remaining_ms)
      attempt(opts, exchange_request, request, deadline, retry)
    end
  end

  # One provider call, capped per attempt and by the wall budget. Retryable failures back off
  # with jitter and retry inside that budget; after an overload streak the next model is used.
  defp attempt(opts, exchange_request, request, deadline, retry) do
    probe = RequestLog.start()
    result = provider_call(opts, request, attempt_budget(opts, deadline), probe)

    :ok =
      Kogen.Agents.activity("#{exchange_request.stage} turn #{exchange_request.turn}", :running)

    with :ok <- log_request(opts, exchange_request, request, retry, probe, result) do
      case result do
        {:error, %ProviderError{class: class} = error} ->
          decision = Retry.next(opts.resilience, retry, class, remaining_ms(deadline))
          after_failure(opts, {exchange_request, request, deadline}, {error, retry, decision})

        _result ->
          record_response(opts, exchange_request, Recovery.complete(request, result))
      end
    end
  end

  # Every provider call leaves one request record in the run journal, whatever its outcome.
  defp log_request(opts, exchange_request, request, retry, probe, result) do
    meta =
      exchange_request
      |> Map.take([:stage, :turn, :model, :effort])
      |> Map.merge(%{
        retries: retry.attempt - 1,
        history: Codec.history_size(request.input),
        resumed: request.continuation_items != [],
        tags:
          Map.put(opts.request_tags, :conversation_id, conversation_key(opts, exchange_request)),
        settings: request_settings(opts, request)
      })
      |> Map.put(:request_shape, Conversation.request_metrics(exchange_request, result))

    with {:ok, transcript_path} <- Recording.path(opts) do
      case RequestLog.append(
             Path.dirname(transcript_path),
             RequestLog.record(probe, meta, result)
           ) do
        :ok -> :ok
        {:error, reason} -> {:error, request_log_error(reason)}
      end
    end
  end

  defp request_log_error(reason),
    do: %Error{
      reason: :request_log_failed,
      detail: "Cannot append request record: #{inspect(reason)}"
    }

  defp after_failure(opts, {exchange_request, _request, deadline}, {error, _retry, :stop}) do
    error =
      if is_integer(deadline) and Policy.overload_budget_bound?(opts.resilience, error.class) do
        %{
          error
          | class: :timeout,
            message: "Wall budget exhausted retrying overloads: " <> error.message
        }
      else
        error
      end

    record_response(opts, exchange_request, {:error, error})
  end

  defp after_failure(
         opts,
         {exchange_request, request, deadline},
         {error, retry, {:retry, next, delay_ms, fallback}}
       ) do
    request = Recovery.continue(request, error)
    exchange_request = %{exchange_request | items: request.input}
    {next_exchange, next_request} = switch_model(opts, exchange_request, request, fallback)

    with :ok <- record_provider_error(opts, exchange_request, error),
         :ok <- record_retry(opts, exchange_request, retry, error, delay_ms),
         :ok <- record_fallback(opts, exchange_request, retry, fallback),
         :ok <- backoff(delay_ms),
         :ok <-
           Recording.append(
             opts,
             :request,
             next_exchange.stage,
             next_exchange.turn,
             next_request
           ) do
      attempt(opts, next_exchange, next_request, deadline, next)
    end
  end

  defp attempt_budget(opts, deadline) do
    case remaining_ms(deadline) do
      :infinity -> opts.resilience.request_cap_ms
      remaining -> min(remaining, opts.resilience.request_cap_ms)
    end
  end

  defp backoff(delay_ms) do
    receive do
    after
      delay_ms -> :ok
    end
  end

  defp switch_model(_opts, exchange_request, request, nil), do: {exchange_request, request}

  defp switch_model(opts, exchange_request, request, {model, effort}) do
    items = Codec.without_reasoning(exchange_request.items)
    switched = %{exchange_request | model: model, effort: effort, items: items}
    next_request = build_request(opts, switched)

    {switched,
     %{next_request | continuation_items: Codec.without_reasoning(request.continuation_items)}}
  end

  defp record_provider_error(opts, exchange_request, error),
    do:
      Recording.append(
        opts,
        :provider_error,
        exchange_request.stage,
        exchange_request.turn,
        error
      )

  defp record_retry(opts, exchange_request, retry, error, delay_ms) do
    record_event(opts, exchange_request, %{
      event: :provider_retry,
      stage: exchange_request.stage,
      turn: exchange_request.turn,
      attempt: retry.attempt,
      reason: error.class,
      delay_ms: delay_ms,
      model: elem(retry.model, 0),
      detail:
        "Retrying model request after #{error.class}; carrying received progress when available."
    })
  end

  defp record_fallback(_opts, _exchange_request, _retry, nil), do: :ok

  defp record_fallback(opts, exchange_request, retry, {model, effort}) do
    {from_model, from_effort} = retry.model

    record_event(opts, exchange_request, %{
      event: :model_fallback,
      stage: exchange_request.stage,
      turn: exchange_request.turn,
      from: %{model: from_model, effort: from_effort},
      to: %{model: model, effort: effort},
      reason: :overload,
      detail:
        "Falling back after #{opts.resilience.overload_fallback_after} consecutive overloads."
    })
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

  defp remaining_ms(:infinity), do: :infinity
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp wall_deadline(:infinity), do: :infinity
  defp wall_deadline(remaining_ms), do: System.monotonic_time(:millisecond) + remaining_ms

  defp build_request(opts, request) do
    %{
      Codec.request(
        request.model,
        request.effort,
        request.instructions,
        request.items,
        request.tool_names
      )
      | prompt_cache_key: conversation_key(opts, request),
        session_id: PromptCacheKey.for_run_stage(opts.run_dir, :session),
        model_generation_tokens:
          if(request.stage == :develop,
            do: Map.get(opts.project.build || %{}, :model_generation_tokens)
          ),
        text_verbosity: if(request.model == "gpt-6-luna", do: :low),
        reasoning_summary: if(request.model == "gpt-6-luna", do: :none, else: :auto),
        adapter: luna_mode(opts, request.model),
        reasoning_context: if(luna_mode(opts, request.model) == :lite, do: :all_turns)
    }
  end

  defp conversation_key(opts, request),
    do: PromptCacheKey.for_run_stage(opts.run_dir, request.stage, opts.request_tags)

  defp luna_mode(opts, "gpt-6-luna"),
    do: Map.get(opts.project.build || %{}, :luna_provider_mode, :responses) || :responses

  defp luna_mode(_opts, _model), do: :responses

  defp request_settings(opts, request) do
    request
    |> RequestLog.settings(opts.provider_config)
    |> Map.put(
      :tool_result_tokens,
      Map.get(opts.project.build || %{}, :tool_result_tokens) || 2_000
    )
  end

  defp provider_call(opts, %ModelRequest{} = request, remaining_ms, probe) do
    request = %{
      request
      | on_progress: RequestLog.progress_marker(probe),
        on_byte: RequestLog.first_byte_marker(probe)
    }

    idle_ms = opts.resilience.stream_idle_ms

    first_byte_ms =
      if is_map(opts.provider_config),
        do:
          min(
            Map.get(opts.provider_config, :first_byte_timeout_ms, opts.resilience.first_byte_ms),
            opts.resilience.first_byte_ms
          ),
        else: opts.resilience.first_byte_ms

    ProviderCall.run(
      opts.provider_mod,
      opts.provider_config,
      request,
      remaining_ms,
      idle_ms,
      first_byte_ms
    )
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
end
