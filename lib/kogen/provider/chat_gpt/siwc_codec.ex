defmodule Kogen.Provider.ChatGPT.SIWCCCodec do
  @moduledoc false

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT.Codec.Errors

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
      "reasoning" => %{"effort" => request.effort, "summary" => "auto"},
      "store" => false,
      "stream" => true
    }

    body =
      if is_binary(request.prompt_cache_key),
        do: Map.put(body, "prompt_cache_key", request.prompt_cache_key),
        else: body

    {:ok, body |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    ErlangError -> Errors.malformed()
  end
end
