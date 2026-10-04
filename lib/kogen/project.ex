defmodule Kogen.Project do
  @moduledoc "Loads and validates `.kogen/project.yaml` for an explicit checkout root."
  use Boundary, deps: [Kogen.Contracts, Kogen.Workspace], exports: []

  alias Kogen.Contracts.Project
  alias Kogen.Project.SetupReuse

  @type load_error :: %{line: pos_integer() | nil, message: String.t()}

  @spec load(Path.t()) :: {:ok, Project.t()} | {:error, [load_error()]}
  def load(checkout_root), do: Kogen.Project.Loader.load(checkout_root)

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

  @spec record_setup_reuse(Path.t(), map()) :: :ok | {:error, term()}
  def record_setup_reuse(run_dir, setup_result),
    do: SetupReuse.record_reuse(run_dir, setup_result)
end
