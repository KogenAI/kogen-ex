defmodule Kogen.Provider.ChatGPT.RequestBody do
  @moduledoc false

  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT.Codec.Errors

  # Growing history is last, after all stable controls. Only the closing JSON
  # delimiters separate the previous prompt prefix from appended items.
  @spec encode(map()) :: {:ok, binary()} | {:error, ProviderError.t()}
  def encode(body) do
    history = body |> Map.fetch!("input") |> :json.encode() |> IO.iodata_to_binary()
    static = body |> Map.delete("input") |> :json.encode() |> IO.iodata_to_binary()
    prefix = binary_part(static, 0, byte_size(static) - 1)
    {:ok, prefix <> ~s(,"input":) <> history <> "}"}
  rescue
    ErlangError -> Errors.malformed()
  end
end
