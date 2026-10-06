defmodule Kogen.Queue.Scheduling do
  @moduledoc false

  alias Kogen.Intent
  alias Kogen.Queue.IntentStatus
  alias Kogen.Workspace

  @spec load(IntentStatus.t(), Path.t(), Path.t(), String.t() | nil, map()) ::
          IntentStatus.t()
  def load(%{status: status} = item, _project, _origin, _approval, _env)
      when status not in [:approved, :draft], do: item

  def load(item, project, origin, approval, env) do
    path = ".kogen/intents/#{item.slug}/intent.md"

    with {:ok, bytes} <- source(project, origin, approval, path, env),
         {:ok, intent} <- Intent.parse_binary(bytes, path),
         {:ok, priority} <- waiting_priority(project, path, intent.priority) do
      %{item | blocks_on: intent.blocks_on, priority: priority}
    else
      {:error, issues} when is_list(issues) ->
        %{item | scheduling_error: Enum.map_join(issues, "; ", & &1.message)}

      {:error, reason} ->
        %{item | scheduling_error: "cannot read scheduling metadata: #{inspect(reason)}"}
    end
  end

  defp source(project, _origin, nil, path, _env), do: File.read(Path.join(project, path))

  defp source(_project, origin, approval, path, env),
    do: Workspace.read_file_at(origin, approval, path, env)

  # Priority is a waiting-queue preference. Dependencies and Build scope remain approved.
  defp waiting_priority(project, path, fallback) do
    case File.read(Path.join(project, path)) do
      {:ok, bytes} ->
        case Intent.parse_binary(bytes, path) do
          {:ok, intent} -> {:ok, intent.priority}
          error -> error
        end

      {:error, :enoent} ->
        {:ok, fallback}

      error ->
        error
    end
  end
end
