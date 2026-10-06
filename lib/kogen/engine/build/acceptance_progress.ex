defmodule Kogen.Engine.Build.AcceptanceProgress do
  @moduledoc false

  alias Kogen.Engine.Build.Session
  alias Kogen.State

  @spec capture(Session.t()) :: Session.t()
  def capture(%Session{intent: %{acceptance: []}} = session), do: session
  def capture(%Session{acceptance: [_ | _]} = session), do: session

  def capture(session) do
    case Kogen.Checks.acceptance(
           session.workdir,
           session.intent,
           session.run_dir,
           session.process_env,
           session.git_env,
           session.sandbox
         ) do
      {:ok, acceptance} ->
        :ok = State.record(session.run, %{event: :acceptance_result, ledger: acceptance.ledger})
        %{session | acceptance: acceptance.ledger}

      {:error, _unverified} ->
        session
    end
  end
end
