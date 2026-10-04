defmodule Kogen.Provider.ChatGPT.Codec do
  @moduledoc "Encodes ChatGPT Responses requests and decodes JSON/SSE streams."
  alias Kogen.Contracts.JSON
  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Contracts.ToolCall
  alias Kogen.Provider.ChatGPT.Codec.Errors
  alias Kogen.Provider.ChatGPT.Codec.Recording
  alias Kogen.Provider.ChatGPT.Codec.Stream
  alias Kogen.Provider.ChatGPT.SIWCCCodec
  alias Kogen.Provider.ChatGPT.SSE

  @type credentials :: {String.t(), String.t()}
  @type recording :: {String.t(), String.t(), [binary()]}
  @spec encode_request(ModelRequest.t(), :codex | :siwc) ::
          {:ok, binary()} | {:error, ProviderError.t()}
  def encode_request(%ModelRequest{} = request, mode \\ :codex) when mode in [:codex, :siwc] do
    if valid_request?(request) do
      case mode do
        :codex -> request |> request_body() |> encode_json()
        :siwc -> SIWCCCodec.encode_request(request)
      end
    else
      Errors.malformed()
    end
  end

  @spec recording_request(String.t(), String.t(), String.t()) :: ModelRequest.t()
  def recording_request(scenario, model, effort),
    do: Recording.recording_request(scenario, model, effort)

  @spec decode_credentials(binary()) :: {:ok, credentials()} | {:error, ProviderError.t()}
  def decode_credentials(contents) when is_binary(contents) do
    case decode_json(contents) do
      {:ok, %{"tokens" => tokens}} when is_map(tokens) ->
        decode_credentials(Map.get(tokens, "access_token"), Map.get(tokens, "account_id"))

      _ ->
        Errors.login()
    end
  end

  def decode_credentials(_contents), do: Errors.login()

  @spec decode_recording(binary()) :: {:ok, recording()} | {:error, ProviderError.t()}
  def decode_recording(contents) when is_binary(contents),
    do: Recording.decode_recording(contents)

  @spec encode_recording(ModelRequest.t(), [binary()]) ::
          {:ok, binary()} | {:error, ProviderError.t()}
  def encode_recording(%ModelRequest{} = request, event_lines) when is_list(event_lines) do
    case request_fingerprint(request) do
      {:ok, fingerprint} -> Recording.encode_recording(request.model, fingerprint, event_lines)
      {:error, %ProviderError{} = provider_error} -> {:error, provider_error}
    end
  end

  @spec request_fingerprint(ModelRequest.t()) :: {:ok, String.t()} | {:error, ProviderError.t()}
  def request_fingerprint(%ModelRequest{} = request) do
    with true <- valid_request?(request),
         {:ok, encoded} <-
           request |> Map.put(:prompt_cache_key, nil) |> request_body() |> encode_json() do
      digest = :sha256 |> :crypto.hash(encoded) |> Base.encode16(case: :lower)
      {:ok, digest}
    else
      false -> {:error, Errors.provider(:malformed)}
      {:error, %ProviderError{} = provider_error} -> {:error, provider_error}
    end
  end

  @spec new_stream() :: Stream.t()
  def new_stream, do: SSE.new_stream()

  @spec feed(Stream.t(), binary()) :: Stream.t()
  def feed(%Stream{} = stream, chunk) when is_binary(chunk),
    do: SSE.feed(stream, chunk, &decode_event/2)

  @spec finish(Stream.t()) :: {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
  def finish(%Stream{} = stream) do
    stream = SSE.flush(stream, &decode_event/2)

    cond do
      not is_nil(stream.failure) -> {:error, stream.failure}
      stream.malformed? -> Errors.malformed()
      is_nil(stream.completed) -> Errors.malformed()
      true -> response(stream)
    end
  end

  @spec sse_lines(binary()) :: {:ok, [binary()]} | {:error, ProviderError.t()}
  def sse_lines(body) when is_binary(body) do
    stream = new_stream() |> SSE.feed(body, &decode_event/2) |> SSE.flush(&decode_event/2)
    if stream.malformed?, do: Errors.malformed(), else: {:ok, Enum.reverse(stream.event_lines)}
  end

  def sse_lines(_body), do: Errors.malformed()

  defp valid_request?(request) do
    is_binary(request.model) and request.model != "" and is_binary(request.effort) and
      request.effort != "" and is_binary(request.instructions) and is_list(request.input) and
      is_list(request.tools) and
      (is_nil(request.previous_response_id) or is_binary(request.previous_response_id)) and
      (is_nil(request.prompt_cache_key) or is_binary(request.prompt_cache_key))
  end

  defp request_body(request) do
    body = %{
      "model" => request.model,
      "instructions" => request.instructions,
      "input" => request.input,
      "tools" => request.tools,
      "reasoning" => %{"effort" => request.effort},
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"]
    }

    case_result =
      case request.previous_response_id do
        nil -> body
        response_id -> Map.put(body, "previous_response_id", response_id)
      end

    maybe_put_prompt_cache_key(case_result, request.prompt_cache_key)
  end

  defp maybe_put_prompt_cache_key(body, cache_key) when is_binary(cache_key),
    do: Map.put(body, "prompt_cache_key", cache_key)

  defp maybe_put_prompt_cache_key(body, _cache_key), do: body

  defp encode_json(value) do
    {:ok, value |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    ErlangError -> Errors.malformed()
  end

  defp decode_event(data, stream) do
    case decode_json(data) do
      {:ok, %{"type" => "response.output_item.done", "item" => item}} when is_map(item) ->
        %{stream | items: [item | stream.items]}

      {:ok, %{"type" => "response.completed", "response" => response}} when is_map(response) ->
        put_completion(stream, response)

      {:ok, %{"type" => type} = event} when type in ["error", "response.failed"] ->
        put_failure(stream, classify_event_error(event))

      {:ok, %{"type" => "response.incomplete"} = event} ->
        put_failure(stream, classify_event_error(event))

      {:ok, %{"error" => error} = event} when not is_nil(error) ->
        put_failure(stream, classify_event_error(event))

      {:ok, event} when is_map(event) ->
        stream

      _ ->
        %{stream | malformed?: true}
    end
  end

  defp decode_json(data), do: JSON.decode(data)

  defp put_completion(%Stream{completed: nil} = stream, response),
    do: %{stream | completed: response}

  defp put_completion(stream, _response), do: %{stream | malformed?: true}
  defp put_failure(%Stream{failure: nil} = stream, failure), do: %{stream | failure: failure}
  defp put_failure(stream, _failure), do: stream

  defp classify_event_error(event) do
    encoded = event |> :json.encode() |> IO.iodata_to_binary() |> String.downcase()

    cond do
      contains_any?(encoded, ["usage_limit", "usage limit", "rate_limit", "rate limit"]) ->
        Errors.provider(:usage_limit)

      contains_any?(encoded, ["server_is_overloaded", "overloaded", "overload"]) ->
        Errors.provider(:overload)

      true ->
        Errors.provider(:transport)
    end
  rescue
    ErlangError -> Errors.provider(:transport)
  end

  defp contains_any?(text, values), do: Enum.any?(values, &String.contains?(text, &1))

  defp response(stream) do
    with {:ok, completed, id} <- completed_response(stream.completed),
         {:ok, items} <- output_items(completed, stream.items),
         {:ok, calls} <- tool_calls(items),
         {:ok, usage} <- usage(completed["usage"]) do
      {:ok,
       %ModelResponse{
         id: id,
         text: output_text(items),
         tool_calls: calls,
         usage: usage,
         raw_items: items
       }}
    else
      {:error, %ProviderError{} = provider_error} -> {:error, provider_error}
    end
  end

  defp completed_response(%{"status" => "completed", "id" => id} = completed)
       when is_binary(id) and id != "", do: {:ok, completed, id}

  defp completed_response(_completed), do: Errors.malformed()

  defp output_items(%{"output" => []}, streamed) when streamed != [],
    do: streamed |> Enum.reverse() |> valid_items()

  defp output_items(%{"output" => items}, _streamed) when is_list(items), do: valid_items(items)

  defp output_items(_completed, streamed) when streamed != [],
    do: streamed |> Enum.reverse() |> valid_items()

  defp output_items(_completed, _streamed), do: Errors.malformed()

  defp valid_items(items),
    do: if(Enum.all?(items, &is_map/1), do: {:ok, items}, else: Errors.malformed())

  defp output_text(items) do
    items
    |> Enum.filter(&(&1["type"] == "message"))
    |> Enum.flat_map(fn item -> if is_list(item["content"]), do: item["content"], else: [] end)
    |> Enum.filter(&(&1["type"] == "output_text" and is_binary(&1["text"])))
    |> Enum.map_join(& &1["text"])
  end

  defp tool_calls(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, calls} ->
      case tool_call(item) do
        :skip -> {:cont, {:ok, calls}}
        {:ok, call} -> {:cont, {:ok, [call | calls]}}
        :error -> {:halt, Errors.malformed()}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  defp tool_call(%{"type" => "function_call", "call_id" => id, "name" => name} = item)
       when is_binary(id) and id != "" and is_binary(name) and name != "" do
    case arguments(item["arguments"]) do
      {:ok, arguments} -> {:ok, %ToolCall{id: id, name: name, arguments: arguments}}
      _ -> :error
    end
  end

  defp tool_call(%{"type" => "function_call"}), do: :error
  defp tool_call(_item), do: :skip
  defp arguments(arguments) when is_map(arguments), do: {:ok, arguments}

  defp arguments(arguments) when is_binary(arguments) do
    case decode_json(arguments) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_arguments}
    end
  end

  defp arguments(_arguments), do: {:error, :invalid_arguments}

  defp usage(%{"input_tokens" => input, "output_tokens" => output} = usage)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    with {:ok, cached} <- optional_count(usage, "input_tokens_details", "cached_tokens"),
         {:ok, reasoning} <- optional_count(usage, "output_tokens_details", "reasoning_tokens"),
         true <- cached <= input do
      {:ok, %{input: input - cached, cached_input: cached, output: output, reasoning: reasoning}}
    else
      {:error, :invalid_usage} -> Errors.malformed()
      false -> Errors.malformed()
    end
  end

  defp usage(_usage), do: Errors.malformed()

  defp optional_count(usage, details_key, count_key) do
    case usage[details_key] do
      nil -> {:ok, 0}
      %{^count_key => count} when is_integer(count) and count >= 0 -> {:ok, count}
      _ -> {:error, :invalid_usage}
    end
  end

  defp decode_credentials(access_token, account_id) do
    with true <- valid_credentials?(access_token, account_id),
         :ok <- token_not_expired(access_token) do
      {:ok, {access_token, account_id}}
    else
      false -> Errors.login()
      {:error, :invalid_token} -> Errors.login()
      {:error, :expired} -> Errors.login()
    end
  end

  defp valid_credentials?(access_token, account_id) do
    is_binary(access_token) and access_token != "" and is_binary(account_id) and account_id != ""
  end

  defp token_not_expired(token) do
    case String.split(token, ".") do
      [_, payload, _] -> token_payload_expiry(payload)
      _ -> {:error, :invalid_token}
    end
  end

  defp token_payload_expiry(payload) do
    case Base.url_decode64(payload, padding: false) do
      {:ok, decoded} ->
        case decode_json(decoded) do
          {:ok, %{"exp" => expiry}} when is_integer(expiry) ->
            if expiry > :erlang.system_time(:second), do: :ok, else: {:error, :expired}

          _ ->
            {:error, :invalid_token}
        end

      :error ->
        {:error, :invalid_token}
    end
  end
end
