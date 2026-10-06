defmodule Kogen.Grok.Codec do
  @moduledoc "Encodes xAI Responses requests and decodes their SSE stream."

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT.Codec, as: ResponsesCodec

  @spec encode_request(ModelRequest.t()) :: {:ok, binary()} | {:error, ProviderError.t()}
  def encode_request(%ModelRequest{} = request) do
    if valid_request?(request) do
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

      body =
        if is_binary(request.prompt_cache_key),
          do: Map.put(body, "prompt_cache_key", request.prompt_cache_key),
          else: body

      {:ok, body |> :json.encode() |> IO.iodata_to_binary()}
    else
      malformed()
    end
  rescue
    ArgumentError -> malformed()
  end

  def encode_request(_request), do: malformed()

  def new_stream, do: ResponsesCodec.new_stream()
  defdelegate feed(stream, chunk), to: ResponsesCodec
  defdelegate finish(stream), to: ResponsesCodec

  defp valid_request?(request) do
    is_binary(request.model) and request.model != "" and is_binary(request.effort) and
      request.effort != "" and is_binary(request.instructions) and is_list(request.input) and
      is_list(request.tools) and
      (is_nil(request.prompt_cache_key) or is_binary(request.prompt_cache_key))
  end

  defp malformed do
    {:error, %ProviderError{class: :malformed, message: "Grok provider request is malformed."}}
  end
end
