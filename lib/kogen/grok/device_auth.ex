defmodule Kogen.Grok.DeviceAuth do
  @moduledoc "Implements Grok Build's OAuth device-code login without running its CLI."

  alias Kogen.Contracts.ProviderError
  alias Kogen.Grok.CredentialStore
  alias Kogen.Grok.DeviceAuth.Codec
  alias Kogen.Http.Transport

  @issuer "https://auth.x.ai"
  @client_id "b1a00492-073a-47ea-816f-4c329264a828"
  @scopes ~w(openid profile email offline_access grok-cli:access api:access)
  @device_grant "urn:ietf:params:oauth:grant-type:device_code"
  @timeout_ms 20_000

  @type login_result :: %{label: String.t(), email: String.t() | nil}

  @spec login(Path.t(), :file | :keychain, String.t(), keyword()) ::
          {:ok, login_result()} | {:error, ProviderError.t()}
  def login(root, backend, label, opts \\ []) when backend in [:file, :keychain] do
    with true <- CredentialStore.valid_label?(label),
         {:ok, discovery} <- discovery(opts),
         {:ok, device_endpoint, token_endpoint} <- endpoints(discovery, opts),
         {:ok, device} <- request_device(device_endpoint, opts),
         :ok <- show_device(device, opts),
         {:ok, token_response} <- poll(device, token_endpoint, opts),
         {:ok, credentials} <- credentials(token_response, token_endpoint),
         :ok <- CredentialStore.save(root, backend, label, credentials, opts),
         :ok <-
           CredentialStore.update_profile(root, label, %{
             email: credentials.email,
             expires_at: credentials.expires_at,
             signed_in: true
           }) do
      {:ok, %{label: label, email: credentials.email}}
    else
      false -> login_error("Invalid Grok account label.")
      {:error, %ProviderError{} = error} -> {:error, error}
      {:error, reason} -> {:error, login_message(reason)}
    end
  end

  @spec logout(Path.t(), :file | :keychain, String.t(), keyword()) ::
          {:ok, %{label: String.t(), remote_revoked?: false}} | {:error, ProviderError.t()}
  def logout(root, backend, label, opts \\ []) when backend in [:file, :keychain] do
    with true <- CredentialStore.valid_label?(label),
         :ok <- CredentialStore.delete(root, backend, label, opts),
         :ok <- CredentialStore.update_profile(root, label, %{signed_in: false, expires_at: nil}) do
      {:ok, %{label: label, remote_revoked?: false}}
    else
      false -> login_error("Invalid Grok account label.")
      {:error, reason} -> {:error, login_message(reason)}
    end
  end

  defp discovery(opts) do
    issuer = opts |> Keyword.get(:issuer, @issuer) |> String.trim_trailing("/")
    url = Keyword.get(opts, :discovery_url, issuer <> "/.well-known/openid-configuration")

    case Transport.get(url, @timeout_ms, proxy_env: Keyword.get(opts, :proxy_env, %{})) do
      {:ok, status, body} when status in 200..299 ->
        Codec.discovery(body, issuer)

      {:ok, status, _body} ->
        {:error, {:discovery_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp endpoints(discovery, opts) do
    issuer = opts |> Keyword.get(:issuer, @issuer) |> String.trim_trailing("/")

    device_endpoint =
      Keyword.get(opts, :device_endpoint) || discovery.device_authorization_endpoint ||
        issuer <> "/oauth2/device/code"

    token_endpoint = Keyword.get(opts, :token_endpoint) || discovery.token_endpoint

    if valid_endpoint?(device_endpoint, opts) and valid_endpoint?(token_endpoint, opts),
      do: {:ok, device_endpoint, token_endpoint},
      else: {:error, :invalid_oauth_endpoint}
  end

  defp valid_endpoint?(endpoint, opts) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) ->
        true

      %URI{scheme: "http", host: host, userinfo: nil} when is_binary(host) ->
        Keyword.get(opts, :allow_insecure_http, false)

      _invalid ->
        false
    end
  end

  defp valid_endpoint?(_endpoint, _opts), do: false

  defp request_device(endpoint, opts) do
    fields = [{"client_id", @client_id}, {"scope", Enum.join(@scopes, " ")}]

    case Transport.post_form(endpoint, fields, @timeout_ms,
           proxy_env: Keyword.get(opts, :proxy_env, %{})
         ) do
      {:ok, status, body} when status in 200..299 -> Codec.device(body)
      {:ok, status, _body} -> {:error, {:device_request_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp show_device(device, opts) do
    display =
      Keyword.get(opts, :show_device, fn info ->
        IO.puts("Grok sign-in code: #{info.user_code}")
        IO.puts("Open: #{info.verification_uri}")
        :ok
      end)

    case display.(device) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> :ok
    end
  end

  defp poll(device, token_endpoint, opts) do
    interval = Keyword.get(opts, :poll_interval_ms, device.interval_ms)
    deadline = System.monotonic_time(:millisecond) + device.expires_in * 1_000
    poll_until(device, token_endpoint, interval, deadline, opts)
  end

  defp poll_until(device, token_endpoint, interval, deadline, opts) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :device_code_expired}
    else
      wait(min(interval, remaining), opts)

      fields = [
        {"grant_type", @device_grant},
        {"client_id", @client_id},
        {"device_code", device.device_code}
      ]

      request_token(device, token_endpoint, fields, interval, deadline, opts)
    end
  end

  defp request_token(device, endpoint, fields, interval, deadline, opts) do
    case Transport.post_form(endpoint, fields, @timeout_ms,
           proxy_env: Keyword.get(opts, :proxy_env, %{})
         ) do
      {:ok, status, body} when status in 200..299 ->
        Codec.token(body)

      {:ok, status, body} when status in 400..499 ->
        poll_error(device, endpoint, {status, body}, interval, deadline, opts)

      {:ok, status, _body} ->
        {:error, {:device_poll_failed, status, :unexpected_response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp poll_error(device, endpoint, {status, body}, interval, deadline, opts) do
    case Codec.error(body) do
      "authorization_pending" -> poll_until(device, endpoint, interval, deadline, opts)
      "slow_down" -> poll_until(device, endpoint, interval + 5_000, deadline, opts)
      "expired_token" -> {:error, :device_code_expired}
      "access_denied" -> {:error, :authorization_denied}
      other -> {:error, {:device_poll_failed, status, other}}
    end
  end

  defp wait(milliseconds, opts) do
    case Keyword.get(opts, :wait) do
      wait when is_function(wait, 1) ->
        wait.(milliseconds)

      nil ->
        receive do
        after
          milliseconds -> :ok
        end
    end
  end

  defp credentials(%Codec.Token{} = token, token_endpoint) do
    scopes =
      case token.scope do
        scope when is_binary(scope) -> String.split(scope, ~r/\s+/, trim: true)
        _other -> @scopes
      end

    {:ok,
     %CredentialStore{
       access_token: token.access_token,
       refresh_token: token.refresh_token,
       expires_at: System.system_time(:second) + token.expires_in,
       scopes: scopes,
       email: token.email,
       client_id: @client_id,
       token_endpoint: token_endpoint
     }}
  end

  defp login_message(:timeout), do: "Grok sign-in timed out."
  defp login_message(:transport), do: "Grok sign-in could not connect to xAI."
  defp login_message(:authorization_denied), do: "Grok sign-in was cancelled."

  defp login_message(:device_code_expired),
    do: "Grok sign-in code expired; run `kogen provider login grok` again."

  defp login_message(:invalid_oauth_endpoint), do: "Grok returned an invalid sign-in endpoint."

  defp login_message(:invalid_discovery_document),
    do: "Grok returned an invalid sign-in discovery document."

  defp login_message(:invalid_device_response),
    do: "Grok returned an invalid device sign-in response."

  defp login_message(:invalid_token_response),
    do: "Grok returned an invalid sign-in token response."

  defp login_message({:discovery_failed, status}),
    do: "Grok sign-in discovery failed (HTTP #{status})."

  defp login_message({:device_request_failed, status}),
    do: "Grok device sign-in failed (HTTP #{status})."

  defp login_message({:device_poll_failed, status, _error}),
    do: "Grok sign-in polling failed (HTTP #{status})."

  defp login_message(reason), do: "Grok sign-in failed (#{inspect(reason)})."

  defp login_error(message), do: {:error, %ProviderError{class: :login, message: message}}
end
