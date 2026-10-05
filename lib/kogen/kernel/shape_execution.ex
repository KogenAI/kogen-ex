defmodule Kogen.Kernel.ShapeExecution do
  @moduledoc false

  alias Kogen.Engine
  alias Kogen.Engine.Runtime
  alias Kogen.Kernel.BuildConfig
  alias Kogen.Kernel.ShapePaths
  alias Kogen.Kernel.Types.ShapeInputs
  alias Kogen.Proc.Sandbox
  alias Kogen.Provider.ChatGPT
  alias Kogen.Shaper
  alias Kogen.Shaper.Request, as: ShapeRequest
  alias Kogen.Shaper.Result, as: ShapeResult

  @spec run(String.t(), Path.t(), String.t()) :: {:ok, ShapeResult.t()} | {:error, term()}
  def run(slug, project_root, task) do
    with {:ok, runtime} <- Kogen.Kernel.runtime(),
         {:ok, project} <- Kogen.Project.load(project_root),
         {:ok, home} <- runtime_home(runtime),
         {:ok, build_config} <- BuildConfig.load(home, project.build),
         {default_model, default_effort} = BuildConfig.shape_settings(build_config.roles),
         {:ok, runtime, process_env, run_dir} <-
           shape_environment(slug, project_root, runtime, project),
         {:ok, provider_config, _source, _label} <-
           Kogen.Kernel.provider_config(label: project.account),
         {:ok, request} <-
           shape_request(%ShapeInputs{
             slug: slug,
             project_root: project_root,
             task: task,
             model: default_model,
             effort: default_effort,
             project: project,
             provider_config: provider_config,
             runtime: runtime,
             process_env: process_env,
             run_dir: run_dir,
             home: home
           }) do
      Shaper.shape(request)
    end
  end

  defp runtime_home(%Runtime{} = runtime) do
    case Runtime.home(runtime) do
      home when is_binary(home) -> {:ok, home}
      nil -> Kogen.Kernel.RuntimeDiscovery.home()
    end
  end

  defp shape_environment(slug, project_root, runtime, project) do
    run_dir = ShapePaths.run_dir(runtime.base_env, slug)

    runtime =
      runtime
      |> Runtime.add_trusted_workspace(project_root)
      |> Runtime.for_run(run_dir)

    with {:ok, process_env} <- Engine.candidate_environment(project_root, runtime, project) do
      process_env =
        process_env
        |> Runtime.add_trusted_workspace(project_root)
        |> Runtime.for_run(run_dir)

      {:ok, runtime, process_env, run_dir}
    end
  end

  defp shape_request(%ShapeInputs{} = inputs) do
    git_env = Runtime.git_environment(inputs.process_env)

    with {:ok, {setup_cache_root, base_tree_sha}} <-
           ShapePaths.setup_cache(inputs.project_root, inputs.home, git_env) do
      {:ok, build_shape_request(inputs, git_env, setup_cache_root, base_tree_sha)}
    end
  end

  defp build_shape_request(inputs, git_env, setup_cache_root, base_tree_sha) do
    %ShapeRequest{
      workdir: inputs.project_root,
      slug: inputs.slug,
      task: inputs.task,
      model: inputs.model,
      effort: inputs.effort,
      provider_mod: ChatGPT,
      provider_config: inputs.provider_config,
      env: inputs.process_env,
      git_env: git_env,
      run_dir: inputs.run_dir,
      setup_cache_root: setup_cache_root,
      base_tree_sha: base_tree_sha,
      sandbox: %Sandbox{
        enabled:
          inputs.project.sandbox and not Runtime.sandboxed?(inputs.process_env) and
            not Runtime.sandboxed?(inputs.runtime),
        home: inputs.home,
        project_root: inputs.project_root,
        origin: inputs.project_root,
        workspace: inputs.project_root,
        run_dir: inputs.run_dir,
        tmp_dir: Runtime.temporary_directory(inputs.process_env),
        workspace_is_project: true
      }
    }
  end
end
