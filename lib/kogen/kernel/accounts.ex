defmodule Kogen.Kernel.Accounts do
  @moduledoc """
  Picks the saved provider and login a project uses. Choices live in ~/.kogen/accounts.yaml,
  never in a repo. A committed `account:` in .kogen/project.yaml remains a ChatGPT-only
  compatibility setting.
  """

  alias Kogen.Accounts.Store, as: AccountStore
  alias Kogen.Contracts.Project
  alias Kogen.Kernel.RuntimeDiscovery
  alias Kogen.Workspace.Workspaces

  @spec selection(Path.t(), Project.t()) ::
          {:ok, {:chatgpt | :grok, String.t()}} | {:error, term()}
  def selection(project_root, %Project{} = project) do
    project_path = Workspaces.canonical(project_root)

    with {:ok, root} <- RuntimeDiscovery.provider_root(),
         {:ok, providers} <- AccountStore.provider_choices(root),
         provider =
           bench_provider() ||
             Map.get(providers.projects, project_path) || providers.default || "chatgpt",
         {:ok, choices} <- AccountStore.account_choices(root, provider) do
      chosen = System.get_env("KOGEN_BENCH_ACCOUNT") || Map.get(choices.projects, project_path)

      label =
        chosen ||
          legacy_chatgpt_account(provider, project.account) || choices.default || "default"

      {:ok, {provider_atom(provider), label}}
    end
  end

  @spec label(Path.t(), Project.t()) :: {:ok, String.t()} | {:error, term()}
  def label(project_root, %Project{} = project) do
    with {:ok, {_provider, label}} <- selection(project_root, project), do: {:ok, label}
  end

  @spec provider_choices() ::
          {:ok, %{default: String.t() | nil, projects: map()}} | {:error, term()}
  def provider_choices do
    with {:ok, root} <- RuntimeDiscovery.provider_root(),
         do: AccountStore.provider_choices(root)
  end

  @spec default() :: {:ok, String.t()} | {:error, term()}
  def default do
    with {:ok, root} <- RuntimeDiscovery.provider_root(),
         {:ok, choices} <- AccountStore.account_choices(root, "chatgpt") do
      {:ok, choices.default || "default"}
    end
  end

  defp legacy_chatgpt_account("chatgpt", account) when is_binary(account) do
    IO.write(:stderr, committed_warning(account))
    account
  end

  defp legacy_chatgpt_account(_provider, _account), do: nil

  defp bench_provider do
    case System.get_env("KOGEN_BENCH_PROVIDER") do
      provider when provider in ["chatgpt", "grok"] -> provider
      _invalid -> nil
    end
  end

  defp provider_atom("chatgpt"), do: :chatgpt
  defp provider_atom("grok"), do: :grok

  defp committed_warning(label) do
    "kogen: moved: account in .kogen/project.yaml; use " <>
      "kogen provider use chatgpt --as #{label} --project <checkout>\n"
  end
end
