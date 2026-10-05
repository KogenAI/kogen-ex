defmodule Kogen.Kernel.ProjectContext do
  @moduledoc false

  alias Kogen.Contracts.Project
  alias Kogen.Kernel.Base
  alias Kogen.Kernel.Origin

  @spec resolve(Path.t(), Project.t(), Path.t() | nil, String.t() | nil, map()) ::
          {:ok, Path.t(), String.t()} | {:error, term()}
  def resolve(project_root, %Project{} = project, origin_override, base_override, git_env) do
    with {:ok, origin} <- Origin.resolve(project_root, origin_override, git_env),
         {:ok, base} <- Base.effective(base_override, project.base, project_root, origin, git_env) do
      {:ok, origin, base}
    end
  end
end
