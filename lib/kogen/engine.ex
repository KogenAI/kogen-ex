defmodule Kogen.Engine do
  @moduledoc "Runs approved Builds inside isolated Candidate workspaces."
  use Boundary,
    deps: [
      Kogen.Contracts,
      Kogen.Proc,
      Kogen.Project,
      Kogen.Intent,
      Kogen.Provider,
      Kogen.Build,
      Kogen.Workspace,
      Kogen.State,
      Kogen.Checks,
      Kogen.Harness
    ],
    exports: [Build.Request, Build.Result, Build.Setup, Runtime]

  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Project
  alias Kogen.Engine.Build.Request
  alias Kogen.Engine.Build.Result
  alias Kogen.Engine.Environment
  alias Kogen.Engine.Runtime

  @spec build_recipe(String.t(), String.t(), String.t()) :: Recipe.t()
  def build_recipe(name, model, effort), do: Recipe.for_build(name, model, effort)

  @spec run(Request.t()) :: {:ok, Result.t()} | {:error, term()}
  def run(%Request{} = request), do: Kogen.Engine.Build.Engine.run(request)

  @spec project_environment(Path.t(), Runtime.t()) ::
          {:ok, %{String.t() => String.t()}}
          | {:error, :invalid_toolchain_environment | {:toolchain_failed, String.t()}}
  def project_environment(workdir, %Runtime{} = runtime),
    do: Environment.project(workdir, runtime)

  @spec candidate_environment(Path.t(), Runtime.t(), Project.t()) ::
          {:ok, %{String.t() => String.t()}}
          | {:error, :invalid_toolchain_environment | {:toolchain_failed, String.t()}}
  def candidate_environment(workdir, %Runtime{} = runtime, %Project{env: project_env}) do
    with {:ok, environment} <- project_environment(workdir, runtime) do
      {:ok, Map.merge(environment, project_env)}
    end
  end
end
