defmodule Kogen.Grok.Refresh do
  @moduledoc false

  alias Kogen.Contracts.Lock
  alias Kogen.Grok.CredentialStore
  alias Kogen.Grok.Refresh.Codec
  alias Kogen.Grok.Refresh.Codec.TokenResponse
  alias Kogen.Http.Transport

  @refresh_skew_seconds 300
  @timeout_ms 20_000

  @spec access_token(Path.t(), :file | :keychain, String.t(), keyword()) ::
          {:ok, CredentialStore.t()} | {:error, term()}
  def access_token(root, backend, label, opts \\ []) do
    with {:ok, current} <- CredentialStore.load(root, backend, label, opts) do
      refresh_if_needed(root, backend, label, current, opts)
    end
  end

  @spec force(Path.t(), :file | :keychain, String.t(), String.t(), keyword()) ::
          {:ok, CredentialStore.t()} | {:error, term()}
  def force(root, backend, label, rejected_access_token, opts \\ []) do
    with_lock(root, label, fn ->
      with {:ok, current} <- CredentialStore.load(root, backend, label, opts) do
        if current.access_token == rejected_access_token,
          do: do_refresh(root, backend, label, current, opts),
          else: {:ok, current}
      end
    end)
  end

  defp refresh_if_needed(root, backend, label, current, opts) do
    if fresh?(current) do
      {:ok, current}
    else
      with_lock(root, label, fn ->
        refresh_latest(root, backend, label, opts)
      end)
    end
  end

  defp refresh_latest(root, backend, label, opts) do
    with {:ok, latest} <- CredentialStore.load(root, backend, label, opts) do
      if fresh?(latest), do: {:ok, latest}, else: do_refresh(root, backend, label, latest, opts)
    end
  end

  defp with_lock(root, label, fun) do
    case Lock.with_lock(root, "grok-" <> label, fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_refresh(root, backend, label, current, opts) do
    endpoint = Keyword.get(opts, :token_endpoint, current.token_endpoint)

    fields = [
      {"grant_type", "refresh_token"},
      {"client_id", current.client_id},
      {"refresh_token", current.refresh_token}
    ]

    with {:ok, 200, body} <-
           Transport.post_form(endpoint, fields, @timeout_ms,
             proxy_env: Keyword.get(opts, :proxy_env, %{})
           ),
         {:ok, response} <- Codec.decode(body),
         {:ok, updated} <- refreshed(current, response),
         :ok <- CredentialStore.save(root, backend, label, updated, opts),
         :ok <- CredentialStore.update_profile(root, label, %{expires_at: updated.expires_at}) do
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
         expires_at: System.system_time(:second) + response.expires_in
     }}
  end

  defp fresh?(%CredentialStore{expires_at: expires_at}),
    do: expires_at > System.system_time(:second) + @refresh_skew_seconds
end
