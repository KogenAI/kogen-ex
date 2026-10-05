defmodule Kogen.Kernel do
  @moduledoc "Coordinates Kogen domains and exposes the command-line entry point."
  use Boundary,
    deps: [
      Kogen.Contracts,
      Kogen.Proc,
      Kogen.Project,
      Kogen.Intent,
      Kogen.Provider,
      Kogen.Engine,
      Kogen.Workspace,
      Kogen.State,
      Kogen.Checks,
      Kogen.Harness,
      Kogen.Shaper,
      Kogen.Queue,
      Kogen.Runner,
      Kogen.Cli
    ],
    exports: [
      Approval,
      CLI,
      Types.ApprovalPreview,
      Types.BuildOptions
    ]

  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ProviderError
  alias Kogen.Engine
  alias Kogen.Engine.Build.Request
  alias Kogen.Engine.Build.Result
  alias Kogen.Engine.Runtime
  alias Kogen.Kernel.Accounts
  alias Kogen.Kernel.Approval
  alias Kogen.Kernel.Approval.Request, as: ApprovalRequest
  alias Kogen.Kernel.Base
  alias Kogen.Kernel.BuildConfig
  alias Kogen.Kernel.IntentRemoval
  alias Kogen.Kernel.ProjectContext
  alias Kogen.Kernel.Queueing
  alias Kogen.Kernel.RuntimeDiscovery
  alias Kogen.Kernel.ShapeExecution
  alias Kogen.Kernel.Types.ApprovalPreview
  alias Kogen.Kernel.Types.BuildOptions
  alias Kogen.Kernel.Workspaces
  alias Kogen.Provider.ChatGPT
  alias Kogen.Provider.ChatGPT.CredentialStore
  alias Kogen.Provider.ChatGPT.SIWC
  alias Kogen.Runner
  alias Kogen.Shaper.Result, as: ShapeResult
  alias Kogen.Workspace

  @type toolchain_error ::
          :mise_missing
          | {:toolchain_failed, String.t()}
          | :invalid_toolchain_environment
          | :too_many_script_symlinks
          | {:script_path_unavailable, term()}

  @spec version() :: String.t()
  def version, do: :kogen |> Application.spec(:vsn) |> List.to_string()

  @spec approval_preview(
          String.t(),
          Path.t(),
          Path.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) ::
          {:ok, ApprovalPreview.t()} | {:error, term()}
  def approval_preview(slug, project_root, origin, base, by) do
    with {:ok, runtime} <- runtime(),
         {:ok, project} <- Kogen.Project.load(project_root),
         {:ok, process_env} <- candidate_environment(project_root, runtime, project),
         {:ok, origin, base} <-
           ProjectContext.resolve(
             project_root,
             project,
             origin,
             base,
             Runtime.git_environment(process_env)
           ),
         {:ok, by} <- approval_by(by, project_root, Runtime.git_environment(process_env)),
         {:ok, home} <- runtime_home(runtime) do
      Approval.prepare(%ApprovalRequest{
        slug: slug,
        project_root: project_root,
        origin: origin,
        base: base,
        by: by,
        env: process_env,
        runtime: runtime,
        home: home
      })
    end
  end

  defp approval_by(nil, project_root, git_env), do: Workspace.git_identity(project_root, git_env)
  defp approval_by(by, _project_root, _git_env), do: {:ok, by}

  @spec approve(ApprovalPreview.t()) :: {:ok, String.t()} | {:error, term()}
  def approve(%ApprovalPreview{} = preview), do: Approval.commit(preview)

  @spec remove_intent(String.t(), Path.t(), Path.t() | nil, String.t() | nil, boolean()) ::
          {:ok, String.t()} | {:error, term()}
  def remove_intent(slug, project_root, origin, base, force) do
    IntentRemoval.run(slug, project_root, origin, base, force)
  end

  @spec build(BuildOptions.t()) :: {:ok, Result.t()} | {:error, term()}
  def build(%BuildOptions{} = options) do
    with {:ok, runtime} <- runtime(),
         {:ok, home} <- runtime_home(runtime),
         {:ok, project} <- Kogen.Project.load(options.project_root),
         {:ok, build_config} <- BuildConfig.load(home, project.build),
         {:ok, process_env} <- project_environment(options.project_root, runtime),
         {:ok, account} <- Accounts.label(options.project_root, project),
         {:ok, provider_config, source, label} <- provider_config(label: account),
         {:ok, origin, base} <-
           ProjectContext.resolve(
             options.project_root,
             project,
             options.origin,
             options.base,
             Runtime.git_environment(process_env)
           ) do
      runtime = Runtime.for_project(runtime, process_env)
      role_overrides = BuildConfig.role_overrides(build_config.roles)
      {builder_model, builder_effort} = BuildConfig.builder_settings(build_config.roles)

      request =
        build_request(%{
          options: options,
          home: home,
          origin: origin,
          base: base,
          model: builder_model,
          effort: builder_effort,
          roles: role_overrides,
          build_config: build_config,
          runtime: runtime,
          provider: {provider_config, source, label}
        })

      Runner.run(request)
    end
  end

  @doc false
  @spec build(Request.t()) :: {:ok, Result.t()} | {:error, term()}
  def build(%Request{} = request), do: Runner.run(request)

  @spec shape(String.t(), Path.t(), String.t()) :: {:ok, ShapeResult.t()} | {:error, term()}
  def shape(slug, project_root, task), do: ShapeExecution.run(slug, project_root, task)

  @spec status(Path.t(), Path.t() | nil, String.t() | nil) ::
          {:ok, [Kogen.Queue.IntentStatus.t()]} | {:error, term()}
  defdelegate status(project_root, origin, base), to: Queueing

  @spec overview(Path.t(), Path.t() | nil, String.t() | nil) :: {:ok, map()} | {:error, term()}
  defdelegate overview(project_root, origin, base), to: Queueing

  @spec report(String.t(), Path.t(), Path.t() | nil, String.t() | nil) ::
          {:ok, binary()} | {:error, term()}
  defdelegate report(slug, project_root, origin, base), to: Queueing

  @spec build_summary(String.t(), Path.t(), Path.t() | nil, String.t() | nil) ::
          {:ok, Kogen.Queue.BuildSummary.t() | nil} | {:error, term()}
  defdelegate build_summary(slug, project_root, origin, base), to: Queueing

  @doc false
  @spec reconcile(String.t(), Path.t(), Path.t() | nil, String.t() | nil) ::
          {:ok, :crashed | :landed | :unchanged} | {:error, term()}
  defdelegate reconcile(run_id, project_root, origin, base), to: Queueing

  @spec queue_start(Path.t(), Path.t() | nil, String.t() | nil, (String.t() -> :ok)) ::
          {:ok, map()} | {:running, pos_integer()} | {:error, term()}
  defdelegate queue_start(project_root, origin, base, say), to: Queueing, as: :start

  @spec queue_detach(Path.t(), Path.t() | nil, String.t() | nil) ::
          {:ok, pos_integer(), Path.t()} | {:running, pos_integer()} | {:error, term()}
  defdelegate queue_detach(project_root, origin, base), to: Queueing, as: :detach

  @spec queue_stop(Path.t(), Path.t() | nil, String.t() | nil) ::
          {:stopping, pos_integer()} | :not_running | {:error, term()}
  defdelegate queue_stop(project_root, origin, base), to: Queueing, as: :stop

  @doc false
  @spec workspace_root(Path.t(), Path.t()) :: Path.t()
  def workspace_root(project_root, home), do: Workspaces.root(project_root, home)

  @doc false
  @spec interrupt_builds(Path.t()) :: :ok | {:error, term()}
  defdelegate interrupt_builds(project_root), to: Queueing, as: :interrupt

  @doc false
  @spec project_environment(Path.t(), Runtime.t()) ::
          {:ok, %{String.t() => String.t()}}
          | {
              :error,
              toolchain_error()
            }
  def project_environment(workdir, %Runtime{} = runtime),
    do: Engine.project_environment(workdir, runtime)

  @doc false
  @spec candidate_environment(Path.t(), Runtime.t(), Project.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, toolchain_error()}
  def candidate_environment(workdir, %Runtime{} = runtime, %Project{} = project),
    do: Engine.candidate_environment(workdir, runtime, project)

  @doc false
  @spec runtime() :: {:ok, Runtime.t()} | {:error, toolchain_error()}
  def runtime do
    RuntimeDiscovery.runtime()
  end

  @spec provider_list() :: {:ok, [String.t()]} | {:error, term()}
  def provider_list do
    with {:ok, root} <- RuntimeDiscovery.provider_root(),
         {:ok, profiles} <- CredentialStore.profiles(root),
         {:ok, default} <- Accounts.default() do
      {:ok, Enum.map(profiles, &provider_profile_line(&1, default))}
    end
  end

  @spec provider_use(String.t(), Path.t() | nil) :: :ok | {:error, term()}
  defdelegate provider_use(label, project_root), to: Accounts, as: :use

  @spec provider_login(String.t()) :: {:ok, map()} | {:error, ProviderError.t()}
  def provider_login(label) when is_binary(label) do
    with {:ok, root} <- RuntimeDiscovery.provider_root() do
      SIWC.login(root, RuntimeDiscovery.credential_backend(), label,
        proxy_env: RuntimeDiscovery.proxy_environment(),
        authorize: fn url ->
          IO.puts("Continue with ChatGPT")
          IO.puts(url)
          _ = RuntimeDiscovery.open_browser(url)
          :ok
        end
      )
    end
  end

  @spec provider_logout(String.t()) ::
          {:ok, %{label: String.t(), remote_revoked?: boolean()}} | {:error, ProviderError.t()}
  def provider_logout(label) when is_binary(label) do
    with {:ok, root} <- RuntimeDiscovery.provider_root() do
      SIWC.logout(root, RuntimeDiscovery.credential_backend(), label,
        proxy_env: RuntimeDiscovery.proxy_environment()
      )
    end
  end

  @doc false
  @spec provider_config(keyword()) ::
          {:ok, ChatGPT.Config.t(), :kogen_owned | :custom, String.t()}
          | {
              :error,
              ProviderError.t()
            }
  def provider_config(opts \\ []) do
    RuntimeDiscovery.provider_config(opts)
  end

  @doc false
  @spec benchmark_provider_config() ::
          {:ok, ChatGPT.Config.t()} | {:error, ProviderError.t() | :benchmark_auth_unavailable}
  def benchmark_provider_config, do: RuntimeDiscovery.benchmark_provider_config()

  defp provider_profile_line(%CredentialStore.Profile{} = profile, default) do
    state = if profile.signed_in, do: "signed in", else: "signed out"
    plan = if profile.plan_usage, do: " Using ChatGPT plan", else: ""
    email = if is_binary(profile.email), do: " #{profile.email}", else: ""
    expiry = if is_integer(profile.expires_at), do: " expires=#{profile.expires_at}", else: ""
    marker = if profile.label == default, do: " (default)", else: ""
    "chatgpt:#{profile.label}#{marker} #{state}#{email}#{plan}#{expiry}\n"
  end

  defp runtime_home(%Runtime{} = runtime) do
    case Runtime.home(runtime) do
      home when is_binary(home) -> {:ok, home}
      nil -> RuntimeDiscovery.home()
    end
  end

  defp build_request(inputs) do
    %{
      options: options,
      home: home,
      origin: origin,
      base: base,
      model: model,
      effort: effort,
      roles: roles,
      build_config: build_config,
      runtime: runtime,
      provider: {provider_config, source, label}
    } = inputs

    %Request{
      slug: options.slug,
      home: home,
      project_root: options.project_root,
      workspace_root: Workspaces.root(options.project_root, home),
      origin: origin,
      base: base,
      model: model,
      effort: effort,
      recipe:
        Engine.build_recipe(build_config.recipe, model, effort, roles, wall_ms(build_config)),
      runtime: runtime,
      provider_mod: ChatGPT,
      provider_config: provider_config,
      credential_source: source,
      credential_label: label
    }
  end

  defp wall_ms(%{wall_minutes: minutes}) when is_integer(minutes), do: minutes * 60_000
  defp wall_ms(_build_config), do: nil

  @doc false
  @spec effective_base(String.t() | nil, String.t() | nil, Path.t(), Path.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def effective_base(explicit, configured, project, origin, git_env),
    do: Base.effective(explicit, configured, project, origin, git_env)
end
