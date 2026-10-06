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

    {:ok, body |> controls(request) |> :json.encode() |> IO.iodata_to_binary()}
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

    {:ok, body |> controls(request) |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    ErlangError ->
      {:error, %ProviderError{class: :malformed, message: "Invalid model request controls."}}
  end

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
