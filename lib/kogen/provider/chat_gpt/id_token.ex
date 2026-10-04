defmodule Kogen.Provider.ChatGPT.IDToken do
  @moduledoc false

  alias Kogen.Contracts.JSON
  alias Kogen.Http.Transport
  alias Kogen.Provider.ChatGPT.OIDC

  @issuer "https://auth.openai.com"

  @spec validate(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{subject: String.t(), email: String.t() | nil}} | {:error, atom()}
  def validate(token, client_id, nonce, opts \\ [])

  def validate(token, client_id, nonce, opts)
      when is_binary(token) and is_binary(client_id) and is_binary(nonce) do
    with {:ok, header, claims, signing_input, signature} <- token_parts(token),
         %{"alg" => "RS256", "kid" => kid} <- header,
         {:ok, discovery} <- OIDC.discovery(oidc_options(opts)),
         {:ok, keys} <- keys(discovery.jwks_uri, Keyword.get(opts, :proxy_env, %{})),
         {:ok, key} <- signing_key(keys, kid),
         true <- :public_key.verify(signing_input, :sha256, signature, key),
         :ok <- validate_claims(claims, client_id, nonce) do
      {:ok, %{subject: claims["sub"], email: claims["email"]}}
    else
      _invalid -> {:error, :invalid_id_token}
    end
  rescue
    ArgumentError -> {:error, :invalid_id_token}
    ErlangError -> {:error, :invalid_id_token}
  end

  def validate(_token, _client_id, _nonce, _opts), do: {:error, :invalid_id_token}

  defp token_parts(token) do
    case String.split(token, ".") do
      [encoded_header, encoded_claims, encoded_signature] ->
        with {:ok, header_json} <- Base.url_decode64(encoded_header, padding: false),
             {:ok, claims_json} <- Base.url_decode64(encoded_claims, padding: false),
             {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
             {:ok, header} <- decode_object(header_json),
             {:ok, claims} <- decode_object(claims_json) do
          {:ok, header, claims, encoded_header <> "." <> encoded_claims, signature}
        end

      _other ->
        {:error, :invalid_id_token}
    end
  end

  defp decode_object(binary) do
    case JSON.decode(binary) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _invalid -> {:error, :invalid_json}
    end
  end

  defp oidc_options(opts), do: Keyword.take(opts, [:discovery_url, :proxy_env])

  defp keys(url, proxy_env) when is_binary(url) do
    case Transport.get(url, 15_000, proxy_env: proxy_env) do
      {:ok, 200, body} ->
        with {:ok, %{"keys" => keys}} <- decode_object(body), true <- is_list(keys) do
          {:ok, keys}
        else
          _invalid -> {:error, :invalid_jwks}
        end

      _other ->
        {:error, :invalid_jwks}
    end
  end

  defp signing_key(keys, kid) do
    case Enum.find(keys, &(&1["kid"] == kid and &1["kty"] == "RSA")) do
      %{"n" => n, "e" => e} ->
        with {:ok, modulus} <- Base.url_decode64(n, padding: false),
             {:ok, exponent} <- Base.url_decode64(e, padding: false) do
          {:ok,
           {:RSAPublicKey, :binary.decode_unsigned(modulus), :binary.decode_unsigned(exponent)}}
        else
          _invalid -> {:error, :invalid_jwk}
        end

      _not_found ->
        {:error, :key_not_found}
    end
  end

  defp validate_claims(claims, client_id, nonce) do
    current = System.system_time(:second)

    with @issuer <- claims["iss"],
         true <- audience?(claims["aud"], client_id),
         expiry when is_integer(expiry) <- claims["exp"],
         true <- expiry > current,
         ^nonce <- claims["nonce"],
         subject when is_binary(subject) and subject != "" <- claims["sub"] do
      :ok
    else
      _invalid -> {:error, :invalid_claims}
    end
  end

  defp audience?(audience, expected) when is_binary(audience), do: audience == expected
  defp audience?(audiences, expected) when is_list(audiences), do: expected in audiences
  defp audience?(_audience, _expected), do: false
end
