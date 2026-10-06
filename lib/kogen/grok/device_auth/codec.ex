defmodule Kogen.Grok.DeviceAuth.Codec do
  @moduledoc false

  alias Kogen.Contracts.JSON

  @enforce_keys [:issuer]
  defstruct [:issuer, :device_authorization_endpoint, :token_endpoint]

  @type t :: %__MODULE__{
          issuer: String.t(),
          device_authorization_endpoint: String.t() | nil,
          token_endpoint: String.t() | nil
        }

  defmodule Device do
    @moduledoc false
    @enforce_keys [:device_code, :user_code, :verification_uri, :expires_in, :interval_ms]
    defstruct [:device_code, :user_code, :verification_uri, :expires_in, :interval_ms]

    @type t :: %__MODULE__{
            device_code: String.t(),
            user_code: String.t(),
            verification_uri: String.t(),
            expires_in: pos_integer(),
            interval_ms: non_neg_integer()
          }
  end

  defmodule Token do
    @moduledoc false
    @enforce_keys [:access_token, :refresh_token, :expires_in]
    defstruct [:access_token, :refresh_token, :expires_in, :scope, :email]

    @type t :: %__MODULE__{
            access_token: String.t(),
            refresh_token: String.t(),
            expires_in: pos_integer(),
            scope: String.t() | nil,
            email: String.t() | nil
          }
  end

  @spec discovery(binary(), String.t()) :: {:ok, t()} | {:error, :invalid_discovery_document}
  def discovery(body, issuer) do
    with {:ok, values} when is_map(values) <- JSON.decode(body),
         ^issuer <- values["issuer"] do
      {:ok,
       %__MODULE__{
         issuer: issuer,
         device_authorization_endpoint: optional_string(values, "device_authorization_endpoint"),
         token_endpoint: optional_string(values, "token_endpoint")
       }}
    else
      _invalid -> {:error, :invalid_discovery_document}
    end
  end

  @spec device(binary()) :: {:ok, Device.t()} | {:error, :invalid_device_response}
  def device(body) do
    with {:ok, values} when is_map(values) <- JSON.decode(body),
         device_code when is_binary(device_code) and device_code != "" <- values["device_code"],
         user_code when is_binary(user_code) and user_code != "" <- values["user_code"],
         verification_uri when is_binary(verification_uri) and verification_uri != "" <-
           values["verification_uri"],
         expires_in when is_integer(expires_in) and expires_in > 0 <- values["expires_in"],
         interval = values["interval"],
         true <- is_nil(interval) or (is_integer(interval) and interval >= 0) do
      {:ok,
       %Device{
         device_code: device_code,
         user_code: user_code,
         verification_uri:
           optional_string(values, "verification_uri_complete") || verification_uri,
         expires_in: expires_in,
         interval_ms: max(interval || 5, 1) * 1_000
       }}
    else
      _invalid -> {:error, :invalid_device_response}
    end
  end

  @spec token(binary()) :: {:ok, Token.t()} | {:error, :invalid_token_response}
  def token(body) do
    with {:ok, values} when is_map(values) <- JSON.decode(body),
         access_token when is_binary(access_token) and access_token != "" <-
           values["access_token"],
         refresh_token when is_binary(refresh_token) and refresh_token != "" <-
           values["refresh_token"],
         expires_in when is_integer(expires_in) and expires_in > 0 <- values["expires_in"] do
      {:ok,
       %Token{
         access_token: access_token,
         refresh_token: refresh_token,
         expires_in: expires_in,
         scope: optional_string(values, "scope"),
         email: optional_string(values, "email")
       }}
    else
      _invalid -> {:error, :invalid_token_response}
    end
  end

  @spec error(binary()) :: String.t()
  def error(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => value}} when is_binary(value) -> value
      _invalid -> "unknown"
    end
  end

  defp optional_string(values, key) do
    case values[key] do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end
end
