defmodule Kogen.Runner do
  @moduledoc """
  Runs an approved Build: drives the pure Build Cycle over Engine stages and Candidates.
  It owns the multi-Candidate policy of the ladder recipe: rung transitions on fresh
  Candidates, parallel members, the whole-Build wall budget, and the acceptance-test auditor.
  """
  use Boundary,
    deps: [
      Kogen.Contracts,
      Kogen.Build,
      Kogen.Checks,
      Kogen.Engine,
      Kogen.Harness,
      Kogen.State
    ],
    exports: []

  alias Kogen.Engine.Build.Request
  alias Kogen.Engine.Build.Result
  alias Kogen.Runner.Driver

  @spec run(Request.t()) :: {:ok, Result.t()} | {:error, term()}
  def run(%Request{} = request) do
    case Kogen.Engine.start(request) do
      {:started, session, effects} -> Driver.run(session, effects)
      other -> other
    end
  end
end
