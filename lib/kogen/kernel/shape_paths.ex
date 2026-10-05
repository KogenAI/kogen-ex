defmodule Kogen.Kernel.ShapePaths do
  @moduledoc false

  alias Kogen.Engine.Runtime
  alias Kogen.Kernel.Workspaces
  alias Kogen.Workspace

  @spec run_dir(%{String.t() => String.t()}, String.t()) :: Path.t()
  def run_dir(process_env, slug) do
    run_id =
      "#{System.monotonic_time(:microsecond)}-#{System.unique_integer([:positive, :monotonic])}"

    Path.join([
      Runtime.temporary_directory(process_env),
      "kogen-shaper",
      slug,
      run_id
    ])
  end

  @spec setup_cache(Path.t(), Path.t(), %{String.t() => String.t()}) ::
          {:ok, {Path.t(), String.t()}} | {:error, term()}
  def setup_cache(project_root, home, git_env) do
    cache_root = Path.join(Workspaces.root(project_root, home), "setup-cache")

    with {:ok, base_tree_sha} <- Workspace.rev_parse(project_root, "HEAD^{tree}", git_env) do
      {:ok, {cache_root, base_tree_sha}}
    end
  end
end
