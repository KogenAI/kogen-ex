defmodule Kogen.Provider.ChatGPT.SIWC do
  @moduledoc false

  alias Kogen.Contracts.ProviderError
  alias Kogen.Http.Transport
  alias Kogen.Provider.ChatGPT.CredentialStore
  alias Kogen.Provider.ChatGPT.CredentialStore.Profile
  alias Kogen.Provider.ChatGPT.HostId
  alias Kogen.Provider.ChatGPT.IDToken
  alias Kogen.Provider.ChatGPT.Loopback
  alias Kogen.Provider.ChatGPT.OIDC
  alias Kogen.Provider.ChatGPT.PKCE
  alias Kogen.Provider.ChatGPT.SIWC.TokenResponse

  defmodule LoginFlow do
    @moduledoc false
    @enforce_keys [:root, :backend, :label, :previous, :profile, :host_id, :listener, :opts]
    defstruct @enforce_keys
  end

  @authorize_endpoint "https://auth.openai.com/api/accounts/authorize"
  @token_endpoint "https://auth.openai.com/api/accounts/oauth/token"
  @resource "https://api.openai.com/v1"
  @required_scopes ~w(openid profile email offline_access resource.invoke chatgpt.tokens.use.direct)
  @timeout_ms 20_000

  @spec login(Path.t(), :file | :keychain, String.t(), keyword()) ::
          {:ok, map()} | {:error, ProviderError.t()}
  def login(root, backend, label, opts \\ []) do
    with true <- CredentialStore.valid_label?(label),
         {:ok, previous} <- existing_credentials(root, backend, label),
         {:ok, profile} <- CredentialStore.profile(root, label),
         {:ok, host_id} <- HostId.get_or_create(root),
         {:ok, listener} <- Loopback.start(port: Keyword.get(opts, :callback_port, 1455)) do
      try do
        authorize(%LoginFlow{
          root: root,
          backend: backend,
          label: label,
          previous: previous,
          profile: profile,
          host_id: host_id,
          listener: listener,
          opts: opts
        })
      after
        Loopback.close(listener)
      end
    else
      false ->
        error(
          :login,
          "ChatGPT account labels may contain letters, numbers, dots, underscores, and dashes."
        )

      {:error, %ProviderError{} = provider_error} ->
        {:error, provider_error}

      {:error, reason} when reason in [:proxy_auth_unsupported, :invalid_proxy] ->
        error(:transport, transport_message(reason))

      {:error, reason} ->
        error(:login, message(reason))
    end
  end

  @spec logout(Path.t(), :file | :keychain, String.t(), keyword()) ::
          {:ok, %{label: String.t(), remote_revoked?: boolean()}} | {:error, ProviderError.t()}
  def logout(root, backend, label, opts \\ []) do
    with true <- CredentialStore.valid_label?(label),
         {:ok, credentials} <- optional_credentials(root, backend, label),
         remote_revoked? = revoke(credentials, opts),
         :ok <- CredentialStore.delete(root, backend, label),
         :ok <- update_signed_out(root, label, remote_revoked?) do
      {:ok, %{label: label, remote_revoked?: remote_revoked?}}
    else
      false -> error(:login, "Invalid ChatGPT account label.")
      {:error, %ProviderError{} = provider_error} -> {:error, provider_error}
      {:error, reason} -> error(:login, message(reason))
    end
  end

  @doc false
  @spec authorization_url(
          String.t(),
          String.t(),
          String.t(),
          map(),
          :registration | :reauthorization
        ) ::
          String.t()
  def authorization_url(redirect_uri, host_id, state, pkce, mode)
      when mode in [:registration, :reauthorization] do
    client_id = if mode == :registration, do: "dynamic_agent_client", else: pkce.client_id

    params = [
      {"client_id", client_id},
      {"ext_agent_host_id", host_id},
      {"response_type", "code"},
      {"redirect_uri", redirect_uri},
      {"scope", Enum.join(@required_scopes, " ")},
      {"resource", @resource},
      {"state", state},
      {"nonce", pkce.nonce},
      {"code_challenge_method", "S256"},
      {"code_challenge", pkce.challenge}
    ]

    params = if mode == :registration, do: [{"agent_name_hint", "Kogen"} | params], else: params
    @authorize_endpoint <> "?" <> URI.encode_query(params)
  end

  defp authorize(%LoginFlow{} = flow) do
    mode =
      if flow.previous || (flow.profile && is_binary(flow.profile.client_id)),
        do: :reauthorization,
        else: :registration

    client_id =
      (flow.previous && flow.previous.client_id) || (flow.profile && flow.profile.client_id)

    pkce = PKCE.generate()
    pkce = Map.merge(pkce, %{nonce: random_value(), client_id: client_id})
    state = random_value()
    url = authorization_url(flow.listener.redirect_uri, flow.host_id, state, pkce, mode)
    open = Keyword.get(flow.opts, :authorize, fn _url -> :ok end)

    with :ok <- normalize_authorizer(open.(url)),
         {:ok, callback} <- await_callback(flow, state, mode),
         {:ok, result} <- finish_authorization(flow, callback, mode, client_id, pkce) do
      {:ok, result}
    else
      {:error, %ProviderError{} = provider_error} -> {:error, provider_error}
      {:error, reason} -> error(:login, message(reason))
    end
  end

  defp await_callback(flow, state, mode) do
    Loopback.await(flow.listener, state, mode,
      timeout_ms: Keyword.get(flow.opts, :callback_timeout_ms, 300_000)
    )
  end

  defp finish_authorization(flow, callback, mode, client_id, pkce) do
    with {:ok, issued_client_id} <- selected_client_id(callback, client_id, mode),
         {:ok, token_response} <-
           exchange(
             callback.code,
             issued_client_id,
             pkce.verifier,
             flow.listener.redirect_uri,
             flow.opts
           ),
         {:ok, credentials} <-
           credentials(token_response, issued_client_id, pkce.nonce, flow.host_id, flow.opts),
         :ok <- same_identity(credentials, flow.previous, flow.profile),
         :ok <- CredentialStore.save(flow.root, flow.backend, flow.label, credentials),
         first_notice? = not notice_shown?(flow.profile),
         :ok <- update_profile(flow.root, flow.label, credentials) do
      {:ok, %{label: flow.label, email: credentials.email, first_notice?: first_notice?}}
    end
  end

  defp existing_credentials(root, backend, label) do
    case CredentialStore.load(root, backend, label) do
      {:ok, credentials} -> {:ok, credentials}
      {:error, :enoent} -> {:ok, nil}
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exchange(code, client_id, verifier, redirect_uri, opts) do
    url = Keyword.get(opts, :token_endpoint, @token_endpoint)

    body = [
      {"grant_type", "authorization_code"},
      {"client_id", client_id},
      {"code", code},
      {"code_verifier", verifier},
      {"redirect_uri", redirect_uri},
      {"resource", @resource}
    ]

    case Transport.post_form(url, body, @timeout_ms,
           proxy_env: Keyword.get(opts, :proxy_env, %{})
         ) do
      {:ok, status, response} when status in 200..299 -> TokenResponse.decode(response)
      {:ok, status, _response} -> {:error, {:token_exchange_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp credentials(%TokenResponse{} = response, client_id, nonce, host_id, opts) do
    with true <- "chatgpt.tokens.use.direct" in response.scopes,
         {:ok, identity} <-
           IDToken.validate(response.id_token, client_id, nonce, oidc_options(opts)) do
      {:ok,
       %CredentialStore{
         client_id: client_id,
         access_token: response.access_token,
         refresh_token: response.refresh_token,
         id_token: response.id_token,
         expires_at: System.system_time(:second) + response.expires_in,
         scopes: response.scopes,
         subject: identity.subject,
         email: identity.email,
         host_id: host_id
       }}
    else
      false -> {:error, :plan_usage_not_granted}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_token_response}
    end
  end

  defp selected_client_id(%{client_id: nil}, previous, :reauthorization),
    do: if(is_binary(previous), do: {:ok, previous}, else: {:error, :client_id_missing})

  defp selected_client_id(%{client_id: client_id}, nil, :registration)
       when is_binary(client_id) and client_id != "" and client_id != "dynamic_agent_client",
       do: {:ok, client_id}

  defp selected_client_id(%{client_id: returned}, expected, :reauthorization)
       when is_binary(expected) and (is_nil(returned) or returned == expected),
       do: {:ok, expected}

  defp selected_client_id(_callback, _expected, _mode), do: {:error, :client_id_mismatch}

  defp same_identity(_credentials, nil, nil), do: :ok

  defp same_identity(credentials, previous, profile) do
    expected_subject = (previous && previous.subject) || (profile && profile.subject)

    if is_binary(expected_subject) and credentials.subject != expected_subject,
      do: {:error, :account_identity_changed},
      else: :ok
  end

  defp update_profile(root, label, credentials) do
    CredentialStore.update_profile(root, label, %{
      client_id: credentials.client_id,
      subject: credentials.subject,
      email: credentials.email,
      expires_at: credentials.expires_at,
      auth_source: "kogen_owned",
      signed_in: true,
      plan_usage: true,
      notice_shown: true
    })
  end

  defp update_signed_out(root, label, remote_revoked?) do
    with {:ok, profile} <- CredentialStore.profile(root, label) do
      if is_nil(profile) do
        :ok
      else
        CredentialStore.update_profile(root, label, %{
          signed_in: false,
          plan_usage: false,
          remote_revoked: remote_revoked?
        })
      end
    end
  end

  defp optional_credentials(root, backend, label) do
    case CredentialStore.load(root, backend, label) do
      {:ok, credentials} -> {:ok, credentials}
      {:error, reason} when reason in [:enoent, :not_found] -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp revoke(nil, _opts), do: false

  defp revoke(credentials, opts) do
    case OIDC.discovery(oidc_options(opts)) do
      {:ok, %OIDC.Discovery{revocation_endpoint: endpoint}} when is_binary(endpoint) ->
        revoke_at(endpoint, credentials, opts)

      _unavailable ->
        false
    end
  end

  defp revoke_at(endpoint, credentials, opts) do
    case Transport.post_form(
           endpoint,
           [
             {"token", credentials.refresh_token},
             {"token_type_hint", "refresh_token"},
             {"client_id", credentials.client_id}
           ],
           @timeout_ms,
           proxy_env: Keyword.get(opts, :proxy_env, %{})
         ) do
      {:ok, 200, _body} -> true
      _unconfirmed -> false
    end
  end

  defp notice_shown?(%Profile{notice_shown: true}), do: true
  defp notice_shown?(_profile), do: false

  defp oidc_options(opts), do: Keyword.take(opts, [:discovery_url, :proxy_env])

  defp normalize_authorizer(:ok), do: :ok
  defp normalize_authorizer({:error, _reason} = error), do: error
  defp normalize_authorizer(_other), do: :ok

  defp random_value, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp message(:state_mismatch), do: "Sign-in callback state did not match; start login again."

  defp message(:registration_incomplete),
    do: "OpenAI did not return the issued client ID; registration is incomplete."

  defp message(:plan_usage_not_granted),
    do: "ChatGPT plan usage was not authorized for this account."

  defp message(:account_identity_changed),
    do: "This account label belongs to a different ChatGPT account. Choose another label."

  defp message({:authorization_failed, "access_denied"}), do: "ChatGPT sign-in was cancelled."

  defp message({:token_exchange_failed, status}),
    do: "OpenAI token exchange failed (HTTP #{status})."

  defp message(:lock_timeout), do: "Timed out waiting for the ChatGPT credential lock."
  defp message(:invalid_account_label), do: "Invalid ChatGPT account label."
  defp message(_reason), do: "ChatGPT sign-in failed. Check the callback and try again."

  defp transport_message(:proxy_auth_unsupported),
    do:
      "HTTPS proxy URLs with credentials are not supported; configure a proxy URL without credentials."

  defp transport_message(:invalid_proxy),
    do: "HTTPS proxy configuration is invalid; use an http://host:port URL without credentials."

  defp error(class, message), do: {:error, %ProviderError{class: class, message: message}}
end
