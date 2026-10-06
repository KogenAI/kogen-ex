defmodule Kogen.Agents do
  @moduledoc "Daemon-free agent observation through run records."
  use Boundary, deps: [Kogen.Contracts], exports: [Output]

  alias Kogen.Agents.Execution
  alias Kogen.Agents.Store

  @spec run(map(), atom(), (-> term())) :: term()
  def run(%{run_dir: run_dir, project: %{root: project}} = inputs, role, operation),
    do: Execution.run(run_dir, Map.get(inputs, :owner_project) || project, role, operation)

  @spec activity(String.t(), :running | :waiting) :: :ok
  defdelegate activity(detail, status), to: Execution

  @spec list([Path.t()]) :: [map()]
  defdelegate list(roots), to: Store
end
