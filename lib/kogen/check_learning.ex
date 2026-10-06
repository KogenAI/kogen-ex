defmodule Kogen.CheckLearning do
  @moduledoc "Retains recurring Build failures as advisory check proposals, qualified before adoption."
  use Boundary, deps: [Kogen.Contracts, Kogen.Proc, Kogen.State, Kogen.Workspace], exports: []

  alias Kogen.CheckLearning.Mining
  alias Kogen.CheckLearning.Qualification
  alias Kogen.Contracts.Failure
  alias Kogen.State.Run

  @spec observe(Run.t(), map(), Failure.t()) :: :ok | {:error, term()}
  def observe(run, inputs, failure), do: Mining.observe(run, inputs, failure)

  @spec record_effect(Path.t(), Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def record_effect(report, before, checked),
    do: Kogen.CheckLearning.Effect.record(report, before, checked)

  @spec qualify(Path.t(), Path.t(), Path.t(), map()) :: {:ok, map()} | {:error, term()}
  def qualify(proposal_path, spec_path, project_root, env),
    do: Qualification.run(proposal_path, spec_path, project_root, env)
end
