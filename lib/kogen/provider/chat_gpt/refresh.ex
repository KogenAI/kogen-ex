defmodule Kogen.Provider.ChatGPT.Refresh do
  @moduledoc false

  alias Kogen.Http.Transport
  alias Kogen.Provider.ChatGPT.CredentialStore
  alias Kogen.Provider.ChatGPT.Lock
  alias Kogen.Provider.ChatGPT.Refresh.Codec
  alias Kogen.Provider.ChatGPT.Refresh.TokenResponse

  @token_endpoint "https://auth.openai.com/api/accounts/oauth/token"
  @resource "https://api.openai.com/v1"
  @refresh_skew_seconds 300
  @timeout_ms 20_000

  @spec access_token(Path.t(), :file | :keychain, String.t(), keyword()) ::
          {:ok, CredentialStore.t()} | {:error, term()}
  def access_token(root, backend, label, opts \\ []) do
    with {:ok, current} <- CredentialStore.load(root, backend, label) do
      refresh_if_needed(root, backend, label, current, opts)
    end
  end

  @spec force(Path.t(), :file | :keychain, String.t(), String.t(), keyword()) ::
          {:ok, CredentialStore.t()} | {:error, term()}
  def force(root, backend, label, rejected_access_token, opts \\ []) do
    with_lock(root, label, fn ->
      refresh_rejected(root, backend, label, rejected_access_token, opts)
    end)
  end

  defp refresh_if_needed(root, backend, label, current, opts) do
    if fresh?(current) do
      {:ok, current}
    else
      with_lock(root, label, fn -> refresh_if_stale(root, backend, label, opts) end)
    end
  end

  defp refresh_rejected(root, backend, label, rejected_access_token, opts) do
    with {:ok, current} <- CredentialStore.load(root, backend, label) do
      if current.access_token == rejected_access_token,
        do: do_refresh(root, backend, label, current, opts),
        else: {:ok, current}
    end
  end

  defp refresh_if_stale(root, backend, label, opts) do
    with {:ok, current} <- CredentialStore.load(root, backend, label) do
      if fresh?(current),
        do: {:ok, current},
        else: do_refresh(root, backend, label, current, opts)
    end
  end

  defp with_lock(root, label, fun) do
    case Lock.with_lock(root, lock_name(label), fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_refresh(root, backend, label, current, opts) do
    fields = [
      {"grant_type", "refresh_token"},
      {"client_id", current.client_id},
      {"refresh_token", current.refresh_token},
      {"resource", @resource}
    ]

    url = Keyword.get(opts, :token_endpoint, @token_endpoint)

    with {:ok, 200, body} <-
           Transport.post_form(url, fields, @timeout_ms,
             proxy_env: Keyword.get(opts, :proxy_env, %{})
           ),
         {:ok, response} <- Codec.decode(body),
         {:ok, updated} <- refreshed(current, response),
         :ok <- CredentialStore.save(root, backend, label, updated) do
      {:ok, updated}
    else
      {:ok, status, _body} -> {:error, {:refresh_failed, status}}
      {:error, :timeout} -> {:error, :refresh_timeout}
      {:error, :transport} -> {:error, :refresh_transport}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refreshed(current, %TokenResponse{} = response) do
    {:ok,
     %{
       current
       | access_token: response.access_token,
         refresh_token: response.refresh_token || current.refresh_token,
         id_token: response.id_token || current.id_token,
         expires_at: System.system_time(:second) + response.expires_in,
         scopes: response.scopes || current.scopes
     }}
  end

  defp fresh?(%CredentialStore{expires_at: expires_at}),
    do: expires_at > System.system_time(:second) + @refresh_skew_seconds

  defp lock_name(label), do: "chatgpt-" <> label
end
