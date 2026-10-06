defmodule Kogen.ResponseProtocol.Codec do
  @moduledoc false

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ProviderError

  @spec encode_request(ModelRequest.t()) :: {:ok, binary()} | {:error, ProviderError.t()}
  def encode_request(%ModelRequest{} = request) do
    input =
      if request.tools == [],
        do: request.input,
        else: [
          %{"type" => "additional_tools", "role" => "developer", "tools" => request.tools}
          | request.input
        ]

    body = %{
      "model" => request.model,
      "instructions" => request.instructions,
      "input" => input,
      "reasoning" => %{"effort" => request.effort},
      "store" => false,
      "stream" => true
    }

    body =
      if is_binary(request.prompt_cache_key),
        do: Map.put(body, "prompt_cache_key", request.prompt_cache_key),
        else: body

    encode_body(controls(body, request))
  rescue
    ErlangError ->
      {:error, %ProviderError{class: :malformed, message: "Invalid model request controls."}}
  end

  @spec fingerprint_body(binary(), :responses | :lite) :: binary()
  def fingerprint_body(encoded, adapter) do
    body = encoded |> :json.decode() |> Map.update!("reasoning", &Map.delete(&1, "summary"))

    body =
      if adapter == :responses do
        Enum.reduce([{"tool_choice", "auto"}, {"parallel_tool_calls", false}], body, fn
          {key, value}, body ->
            if body[key] == value, do: Map.delete(body, key), else: body
        end)
      else
        body
      end

    body |> :json.encode() |> IO.iodata_to_binary()
  end

  @spec valid_controls?(ModelRequest.t()) :: boolean()
  def valid_controls?(request) do
    request.adapter in [:responses, :lite] and
      request.text_verbosity in [nil, :low, :medium, :high] and
      request.reasoning_summary in [:none, :auto, :concise, :detailed] and
      request.tool_choice in [:auto, :none, :required] and
      is_boolean(request.parallel_tool_calls) and
      (is_nil(request.session_id) or is_binary(request.session_id)) and
      (is_nil(request.model_generation_tokens) or
         (is_integer(request.model_generation_tokens) and request.model_generation_tokens > 0)) and
      valid_lite?(request)
  end

  defp valid_lite?(%{adapter: :lite} = request),
    do:
      request.model == "gpt-6-luna" and is_binary(request.session_id) and request.session_id != "" and
        request.reasoning_context == :all_turns and request.parallel_tool_calls == false and
        is_nil(request.previous_response_id)

  defp valid_lite?(request), do: is_nil(request.reasoning_context)

  @spec controls(map(), ModelRequest.t()) :: map()
  def controls(body, request) do
    reasoning = %{"effort" => request.effort}

    reasoning =
      if request.reasoning_summary == :none,
        do: reasoning,
        else: Map.put(reasoning, "summary", to_string(request.reasoning_summary))

    reasoning =
      if is_nil(request.reasoning_context),
        do: reasoning,
        else: Map.put(reasoning, "context", to_string(request.reasoning_context))

    body =
      body
      |> Map.put("reasoning", reasoning)
      |> Map.put("tool_choice", to_string(request.tool_choice))
      |> Map.put("parallel_tool_calls", request.parallel_tool_calls)

    body =
      if is_nil(request.model_generation_tokens),
        do: body,
        else: Map.put(body, "max_output_tokens", request.model_generation_tokens)

    if is_nil(request.text_verbosity),
      do: body,
      else: Map.put(body, "text", %{"verbosity" => to_string(request.text_verbosity)})
  end

  @spec encode_lite(ModelRequest.t()) :: {:ok, binary()} | {:error, ProviderError.t()}
  def encode_lite(request) do
    tools = %{
      "type" => "additional_tools",
      "role" => "developer",
      "tools" => request.tools,
      "id" => item_id("at", request.session_id, request.tools)
    }

    instructions = %{
      "type" => "message",
      "role" => "developer",
      "id" => item_id("msg", request.session_id, request.instructions),
      "content" => [%{"type" => "input_text", "text" => request.instructions}]
    }

    prefix = if request.instructions == "", do: [tools], else: [tools, instructions]

    body = %{
      "model" => request.model,
      "instructions" => "",
      "input" => prefix ++ request.input,
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"]
    }

    body =
      if is_nil(request.prompt_cache_key),
        do: body,
        else: Map.put(body, "prompt_cache_key", request.prompt_cache_key)

    encode_body(controls(body, request))
  rescue
    ErlangError ->
      {:error, %ProviderError{class: :malformed, message: "Invalid model request controls."}}
  end

  # Growing history is last, after every stable control. Only the closing JSON
  # delimiters separate a previous prompt prefix from appended input items.
  defp encode_body(body) do
    history = body |> Map.fetch!("input") |> :json.encode() |> IO.iodata_to_binary()
    static = body |> Map.delete("input") |> :json.encode() |> IO.iodata_to_binary()
    prefix = binary_part(static, 0, byte_size(static) - 1)
    {:ok, prefix <> ~s(,"input":) <> history <> "}"}
  end

  @spec incomplete_error(term()) :: ProviderError.t()
  def incomplete_error(response) do
    response = if is_map(response), do: response, else: %{}

    reason =
      case detail(response, "incomplete_details", "reason") do
        reason when reason in ["max_output_tokens", "content_filter"] -> reason
        _unknown -> "unknown"
      end

    id =
      case Map.get(response, "id") do
        value when is_binary(value) -> value
        _unknown -> nil
      end

    %ProviderError{
      class: :incomplete,
      message: "Model response incomplete (#{reason}); no tool calls were executed.",
      response_id: id,
      incomplete_reason: reason,
      usage: partial_usage(response["usage"])
    }
  end

  defp partial_usage(usage) when is_map(usage) do
    total_input = count(usage["input_tokens"])
    cached = count(detail(usage, "input_tokens_details", "cached_tokens"))

    input =
      if is_integer(total_input) and is_integer(cached) and cached <= total_input,
        do: total_input - cached

    %{
      input: input,
      cached_input: cached,
      output: count(usage["output_tokens"]),
      reasoning: count(detail(usage, "output_tokens_details", "reasoning_tokens"))
    }
  end

  defp partial_usage(_unknown), do: nil

  defp detail(value, key, field) do
    case Map.get(value, key) do
      details when is_map(details) -> Map.get(details, field)
      _unknown -> nil
    end
  end

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_unknown), do: nil

  defp item_id(prefix, session, payload) do
    namespace = uuid5(<<0x6BA7B8129DAD11D180B400C04FD430C8::128>>, session)
    uuid = uuid5(namespace, IO.iodata_to_binary(:json.encode(payload)))
    <<a::32, b::16, c::16, d::16, e::48>> = uuid

    suffix =
      [a, b, c, d, e]
      |> Enum.zip([8, 4, 4, 4, 12])
      |> Enum.map_join("-", fn {part, width} ->
        part |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
      end)

    prefix <> "_" <> suffix
  end

  defp uuid5(namespace, name) do
    <<a::48, _version::4, b::12, _variant::2, c::62, _rest::binary>> =
      :crypto.hash(:sha, [namespace, name])

    <<a::48, 5::4, b::12, 2::2, c::62>>
  end
end
