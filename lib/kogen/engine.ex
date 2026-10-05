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
      Kogen.Harness,
      Kogen.Resilience
    ],
    exports: [
      Build.CandidateSnapshot,
      Build.CheckStage,
      Build.Commit,
      Build.Escalation,
      Build.Finish,
      Build.GateSupport,
      Build.Request,
      Build.Result,
      Build.Session,
      Build.Setup,
      Build.StageRunner,
      Runtime
    ]

  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Project
  alias Kogen.Engine.Build.Request
  alias Kogen.Engine.Build.Result
  alias Kogen.Engine.Environment
  alias Kogen.Engine.Runtime

  @spec build_recipe(String.t(), String.t(), String.t()) :: Recipe.t()
  def build_recipe(name, model, effort), do: Recipe.for_build(name, model, effort)

  @spec build_recipe(String.t(), String.t(), String.t(), map()) :: Recipe.t()
  def build_recipe(name, model, effort, role_settings) when is_map(role_settings) do
    recipe = Recipe.for_build(name, model, effort)

    roles =
      Enum.reduce(role_settings, recipe.roles, fn {role, settings}, acc ->
        {default_model, default_effort} = Map.get(acc, role, {model, effort})

        Map.put(acc, role, {
          Map.get(settings, :model, default_model),
          Map.get(settings, :effort, default_effort)
        })
      end)

    %{recipe | roles: roles}
  end

  @doc "A recipe with role settings and, for a ladder, the whole-Build wall budget."
  @spec build_recipe(String.t(), String.t(), String.t(), map(), pos_integer() | nil) ::
          Recipe.t()
  def build_recipe(name, model, effort, role_settings, wall_ms) do
    name
    |> build_recipe(model, effort, role_settings)
    |> Recipe.with_wall_ms(wall_ms)
  end

  @doc """
  Prepares an approved Build up to its first Cycle effects: approval and base checks, the run
  journal, the claim, and the first Candidate. A Build that cannot start is already finished.
  """
  @spec start(Request.t()) ::
          {:started, Kogen.Engine.Build.Session.t(), [term()]}
          | {:ok, Result.t()}
          | {:error, term()}
  def start(%Request{} = request), do: Kogen.Engine.Build.Engine.start(request)

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
