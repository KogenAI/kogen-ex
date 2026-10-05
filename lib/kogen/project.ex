defmodule Kogen.Project do
  @moduledoc "Loads and validates `.kogen/project.yaml` for an explicit checkout root."
  use Boundary, deps: [Kogen.Contracts, Kogen.Workspace], exports: [GatePaths]

  alias Kogen.Contracts.Project
  alias Kogen.Project.BuildSettings
  alias Kogen.Project.GatePaths
  alias Kogen.Project.SetupReuse

  @type load_error :: %{line: pos_integer() | nil, message: String.t()}

  @spec load(Path.t()) :: {:ok, Project.t()} | {:error, [load_error()]}
  def load(checkout_root), do: Kogen.Project.Loader.load(checkout_root)

  @spec load_machine_build_settings(Path.t()) :: {:ok, map() | nil} | {:error, [load_error()]}
  def load_machine_build_settings(home), do: BuildSettings.load_machine(home)

  @spec effective_build_settings(map() | nil, map() | nil) :: %{
          recipe: String.t(),
          roles: map(),
          wall_minutes: pos_integer() | nil,
          edge_tests: boolean(),
          model_fallback: boolean()
        }
  def effective_build_settings(machine, project), do: BuildSettings.effective(machine, project)

  @spec run_setup(
          Project.t(),
          Path.t(),
          Path.t() | nil,
          String.t() | nil,
          map(),
          (-> :ok | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def run_setup(project, workdir, cache_root, base_tree_sha, toolchain_env, runner) do
    SetupReuse.run(
      project,
      workdir,
      cache_root,
      base_tree_sha,
      toolchain_env,
      runner
    )
  end

  @spec protected_patterns(Project.t(), boolean(), [String.t()]) :: [String.t()]
  def protected_patterns(project, changes_gate?, tracked_paths),
    do: GatePaths.protected_patterns(project, changes_gate?, tracked_paths)

  @spec absent_candidates([String.t()], [String.t()]) :: [String.t()]
  def absent_candidates(patterns, tracked_paths),
    do: GatePaths.absent_candidates(patterns, tracked_paths)

  @spec record_setup_reuse(Path.t(), map()) :: :ok | {:error, term()}
  def record_setup_reuse(run_dir, setup_result),
    do: SetupReuse.record_reuse(run_dir, setup_result)
end
