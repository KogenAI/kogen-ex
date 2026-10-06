defmodule Kogen.Shaping do
  @moduledoc "Rechecks the approved product assumptions before a Build starts."
  use Boundary, deps: [Kogen.Contracts, Kogen.Workspace, Kogen.State], exports: []

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.State
  alias Kogen.Workspace

  @spec recheck(Intent.t(), Path.t(), String.t(), String.t(), map()) ::
          {:ok, [map()]} | {:error, Failure.t()}
  def recheck(intent, origin, base, branch, env) do
    with {:ok, evidence} <- checks(intent.shaping_checks, origin, base, env),
         {:ok, dependencies} <- dependencies(intent.blocks_on, origin, branch, env) do
      {:ok, evidence ++ dependencies}
    else
      {:error, %Failure{}} = error ->
        error

      {:error, reason} ->
        {:error,
         %Failure{class: :environment, reason: :shaping_recheck_failed, detail: inspect(reason)}}
    end
  end

  @spec record(Kogen.State.Run.t(), tuple(), String.t()) :: :ok | {:error, term()}
  def record(run, {:ok, evidence}, base) do
    State.record(run, %{event: :shaping_rechecked, base_sha: base, result: evidence})
  end

  def record(run, {:error, failure}, base) do
    with :ok <-
           State.record(run, %{
             event: :shaping_stale,
             base_sha: base,
             reason: failure.reason,
             detail: failure.detail
           }) do
      {:error, failure}
    end
  end

  defp checks(checks, origin, base, env) do
    Enum.reduce_while(checks, {:ok, []}, fn check, {:ok, evidence} ->
      case Workspace.read_file_at(origin, base, check.path, env) do
        {:ok, bytes} ->
          if String.contains?(bytes, check.contains) do
            {:cont, {:ok, evidence ++ [%{check: check, matched: true}]}}
          else
            {:halt, stale(check, "expected contract text is absent")}
          end

        {:error, reason} ->
          {:halt, stale(check, "cannot verify current base: #{inspect(reason)}")}
      end
    end)
  end

  defp dependencies([], _origin, _branch, _env), do: {:ok, []}

  defp dependencies(slugs, origin, branch, env) do
    with {:ok, snapshot} <- Workspace.status_snapshot(origin, branch, env, false) do
      Enum.reduce_while(slugs, {:ok, []}, fn slug, {:ok, evidence} ->
        case Map.get(snapshot.landed, slug) do
          nil ->
            check = %{kind: "dependency", name: slug, path: slug}
            {:halt, stale(check, "dependency has no landed outcome on #{branch}")}

          sha ->
            {:cont, {:ok, evidence ++ [%{dependency: slug, landed_sha: sha}]}}
        end
      end)
    end
  end

  defp stale(check, reason) do
    {:error,
     %Failure{
       class: :candidate,
       reason: :shaping_stale,
       detail:
         "Changed #{check.kind} #{check.name} (#{check.path}): #{reason}. " <>
           "Reshape the Intent or renew approval with updated assumptions; the requested UX has not been reinterpreted."
     }}
  end
end
