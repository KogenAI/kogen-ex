defmodule Kogen.Provider.ChatGPT.OIDC.Discovery do
  @moduledoc false

  @enforce_keys [:issuer, :jwks_uri]
  defstruct [:issuer, :jwks_uri, :revocation_endpoint]

  @type t :: %__MODULE__{
          issuer: String.t(),
          jwks_uri: String.t(),
          revocation_endpoint: String.t() | nil
        }
end

defmodule Kogen.Provider.ChatGPT.OIDC do
  @moduledoc false

  alias Kogen.Contracts.JSON
  alias Kogen.Http.Transport
  alias Kogen.Provider.ChatGPT.OIDC.Discovery

  @discovery_url "https://auth.openai.com/.well-known/openid-configuration"
  @timeout_ms 15_000

  @spec discovery(keyword()) :: {:ok, Discovery.t()} | {:error, term()}
  def discovery(opts \\ []) do
    url = Keyword.get(opts, :discovery_url, @discovery_url)

    with {:ok, 200, body} <-
           Transport.get(url, @timeout_ms, proxy_env: Keyword.get(opts, :proxy_env, %{})),
         {:ok, discovery} <- decode_object(body),
         issuer when is_binary(issuer) <- discovery["issuer"],
         true <- issuer == "https://auth.openai.com",
         jwks_uri when is_binary(jwks_uri) <- discovery["jwks_uri"] do
      revocation_endpoint = discovery["revocation_endpoint"]
      revocation_endpoint = if is_binary(revocation_endpoint), do: revocation_endpoint

      {:ok,
       %Discovery{
         issuer: issuer,
         jwks_uri: jwks_uri,
         revocation_endpoint: revocation_endpoint
       }}
    else
      {:ok, status, _body} when status in 500..599 -> {:error, :service_unavailable}
      _invalid -> {:error, :discovery_failed}
    end
  end

  defp decode_object(body) do
    case JSON.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _invalid -> {:error, :invalid_json}
    end
  end
end
