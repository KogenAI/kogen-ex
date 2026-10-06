defmodule Kogen.ProviderControl do
  @moduledoc "Coordinates provider login, account selection, and local provider status."
  use Boundary,
    deps: [Kogen.Accounts, Kogen.Contracts, Kogen.Grok, Kogen.Provider],
    exports: []

  alias Kogen.Accounts.Store
  alias Kogen.Contracts.ProviderError
  alias Kogen.Grok.CredentialStore, as: GrokCredentials
  alias Kogen.Grok.DeviceAuth
  alias Kogen.Provider.ChatGPT.CredentialStore, as: ChatGPTCredentials
  alias Kogen.Provider.ChatGPT.SIWC

  @spec list(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(root) do
    with {:ok, selected} <- Store.provider_choices(root),
         provider = selected.default || "chatgpt",
         {:ok, accounts} <- Store.account_choices(root, provider),
         {:ok, chatgpt} <- ChatGPTCredentials.profiles(root),
         {:ok, grok} <- GrokCredentials.profiles(root) do
      default_label = accounts.default || "default"
      lines = profile_lines(chatgpt, "chatgpt", provider, default_label)
      lines = lines ++ profile_lines(grok, "grok", provider, default_label)

      {:ok,
       if(lines == [], do: ["chatgpt: not signed in\n", "grok: not signed in\n"], else: lines)}
    end
  end

  @spec login(String.t(), Path.t(), :file | :keychain, String.t(), keyword()) ::
          {:ok, map()} | {:error, ProviderError.t()}
  def login("chatgpt", root, backend, label, opts) do
    SIWC.login(root, backend, label, opts)
  end

  def login("grok", root, backend, label, opts) do
    DeviceAuth.login(root, backend, label, opts)
  end

  @spec logout(String.t(), Path.t(), :file | :keychain, String.t(), keyword()) ::
          {:ok, map()} | {:error, ProviderError.t()}
  def logout("chatgpt", root, backend, label, opts) do
    SIWC.logout(root, backend, label, opts)
  end

  def logout("grok", root, backend, label, _opts), do: DeviceAuth.logout(root, backend, label)

  @spec use(Path.t(), String.t(), String.t(), :default | {:project, Path.t()}) ::
          :ok | {:error, term()}
  def use(root, provider, label, target) when provider in ["chatgpt", "grok"] do
    with :ok <- saved(provider, label, profiles(root, provider)),
         :ok <- Store.put_account_choice(root, provider, target, label) do
      Store.put_provider_choice(root, target, provider)
    end
  end

  defp profiles(root, "chatgpt"), do: ChatGPTCredentials.profiles(root)
  defp profiles(root, "grok"), do: GrokCredentials.profiles(root)

  defp saved(_provider, label, {:ok, profiles}) do
    if Enum.any?(profiles, &(&1.label == label)), do: :ok, else: {:error, missing_login(label)}
  end

  defp saved(_provider, _label, {:error, reason}), do: {:error, reason}

  defp missing_login(label) do
    %ProviderError{
      class: :login,
      message:
        "Selected account #{label} has no saved login; run kogen provider login <provider> to sign in"
    }
  end

  defp profile_lines(profiles, provider, default_provider, default_label) do
    Enum.map(profiles, &profile_line(&1, provider, default_provider, default_label))
  end

  defp profile_line(profile, provider, default_provider, default_label) do
    state = if profile.signed_in, do: "signed in", else: "signed out"
    email = if is_binary(profile.email), do: " #{profile.email}", else: ""
    expiry = if is_integer(profile.expires_at), do: " expires=#{profile.expires_at}", else: ""

    marker =
      if provider == default_provider and profile.label == default_label,
        do: " (default)",
        else: ""

    "#{provider}:#{profile.label}#{marker} #{state}#{email}#{expiry}\n"
  end
end
