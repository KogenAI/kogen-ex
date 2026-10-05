defmodule Kogen.Engine.Build.RunEvents do
  @moduledoc false

  alias Kogen.Build.Recipe
  alias Kogen.Engine.Build.Request
  alias Kogen.State
  alias Kogen.State.Approval
  alias Kogen.State.Run

  @spec started(Run.t(), Request.t(), Approval.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def started(
        %Run{} = run,
        %Request{} = request,
        %Approval{} = approval,
        approval_commit,
        base_sha
      ) do
    State.record(run, %{
      event: :started,
      approval_commit: approval_commit,
      approved_by: approval.by,
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

  @spec base_drift(Run.t(), [String.t()], String.t()) :: :ok | {:error, term()}
  def base_drift(run, paths, base) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case State.record(run, %{
             event: :base_drift,
             path: path,
             base_sha: base,
             detail: "Using protected file #{path} from current base #{base}."
           }) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
