defmodule Kogen.Engine.Build.RunEvents do
  @moduledoc false

  alias Kogen.Build.Recipe
  alias Kogen.Engine.Build.Request
  alias Kogen.State
  alias Kogen.State.Run

  @spec started(Run.t(), Request.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def started(%Run{} = run, %Request{} = request, approval_commit, base_sha) do
    State.record(run, %{
      event: :started,
      approval_commit: approval_commit,
      base_sha: base_sha,
      model: request.model,
      effort: request.effort,
      roles: Recipe.role_settings(request.recipe),
      credential_source: request.credential_source,
      credential_label: request.credential_label,
      recipe: Recipe.name(request.recipe),
      escalation: Recipe.escalation(request.recipe)
    })
  end
end
