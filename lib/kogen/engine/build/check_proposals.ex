defmodule Kogen.Engine.Build.CheckProposals do
  @moduledoc false
  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.GateSupport
  alias Kogen.Engine.Build.Session
  alias Kogen.State

  require Logger

  @spec observe(Session.t(), Failure.t() | nil, atom()) :: :ok
  def observe(_session, nil, _stage), do: :ok

  def observe(session, failure, stage) do
    {model, _effort} = GateSupport.builder_settings(session)

    context = %{
      workdir: session.workdir,
      base_sha: session.base_sha,
      git_env: session.git_env,
      model: model,
      attempt: session.attempt,
      repairs_left: session.cycle.repairs_left,
      stage: stage
    }

    case Kogen.CheckLearning.observe(session.run, context, failure) do
      :ok ->
        :ok

      {:error, reason} ->
        _record =
          State.record(session.run, %{event: :check_proposal_failed, detail: inspect(reason)})

        Logger.warning("Candidate check proposal evidence failed: #{inspect(reason)}")
    end
  end
end
