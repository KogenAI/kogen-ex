defmodule Kogen.Grok.Refresh.Codec.TokenResponse do
  @moduledoc false
  @enforce_keys [:access_token, :expires_in]
  defstruct [:access_token, :expires_in, :refresh_token]

  @type t :: %__MODULE__{
          access_token: String.t(),
          expires_in: pos_integer(),
          refresh_token: String.t() | nil
        }
end

defmodule Kogen.Grok.Refresh.Codec do
  @moduledoc false

  alias Kogen.Contracts.JSON
  alias Kogen.Grok.Refresh.Codec.TokenResponse

  @spec decode(binary()) :: {:ok, TokenResponse.t()} | {:error, :invalid_refresh_response}
  def decode(body) when is_binary(body) do
    with {:ok, response} <- JSON.decode(body),
         true <- is_map(response),
         access_token when is_binary(access_token) and access_token != "" <-
           response["access_token"],
         expires_in when is_integer(expires_in) and expires_in > 0 <- response["expires_in"],
         {:ok, refresh_token} <- optional_token(response, "refresh_token") do
      {:ok,
       %TokenResponse{
         access_token: access_token,
         expires_in: expires_in,
         refresh_token: refresh_token
       }}
    else
      _invalid -> {:error, :invalid_refresh_response}
    end
  end

  defp optional_token(response, key) do
    case response[key] do
      nil -> {:ok, nil}
      token when is_binary(token) and token != "" -> {:ok, token}
      _invalid -> {:error, :invalid_refresh_response}
    end
  end
end
