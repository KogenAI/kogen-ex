defmodule Kogen.Kernel.Accounts do
  @moduledoc """
  Picks the saved login a project uses: the project's own choice on this machine, else the
  machine default, else the account labelled `default`. Choices live in ~/.kogen/accounts.yaml,
  never in a repo. A committed `account:` in .kogen/project.yaml is honoured for one more CLI
  generation, after the project's own choice, with a `moved:` warning.
  """

  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ProviderError
  alias Kogen.Kernel.RuntimeDiscovery
  alias Kogen.Kernel.Workspaces
  alias Kogen.Provider.ChatGPT.CredentialStore

  @spec label(Path.t(), Project.t()) :: {:ok, String.t()} | {:error, term()}
  def label(project_root, %Project{} = project) do
    with {:ok, root} <- RuntimeDiscovery.provider_root(),
         {:ok, choices} <- CredentialStore.account_choices(root) do
      chosen = Map.get(choices.projects, Workspaces.canonical(project_root))

      cond do
        is_binary(chosen) ->
          {:ok, chosen}

        is_binary(project.account) ->
          IO.write(:stderr, committed_warning(project.account))
          {:ok, project.account}

        true ->
          {:ok, choices.default || "default"}
      end
    end
  end

  @doc "Makes `label` the machine default, or the account for `project_root` when given."
  @spec use(String.t(), Path.t() | nil) :: :ok | {:error, term()}
  def use(label, project_root) do
    target = if project_root, do: {:project, Workspaces.canonical(project_root)}, else: :default

    with {:ok, root} <- RuntimeDiscovery.provider_root(),
         {:ok, profiles} <- CredentialStore.profiles(root),
         :ok <- saved(label, profiles) do
      CredentialStore.put_account_choice(root, target, label)
    end
  end

  @spec default() :: {:ok, String.t()} | {:error, term()}
  def default do
    with {:ok, root} <- RuntimeDiscovery.provider_root(),
         {:ok, choices} <- CredentialStore.account_choices(root) do
      {:ok, choices.default || "default"}
    end
  end

  defp saved(label, profiles) do
    if Enum.any?(profiles, &(&1.label == label)),
      do: :ok,
      else:
        {:error,
         %ProviderError{
           class: :login,
           message:
             "chatgpt:#{label} has no saved login; run kogen provider login chatgpt --as #{label}"
         }}
  end

  defp committed_warning(label) do
    "kogen: moved: account in .kogen/project.yaml; use " <>
      "kogen provider use chatgpt --as #{label} --project <checkout>\n"
  end
end
