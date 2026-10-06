defmodule Kogen.Workspace.IntentFiles do
  @moduledoc false

  alias Kogen.Contracts.Stack
  alias Kogen.Workspace

  @spec install(Path.t(), String.t(), binary(), %{String.t() => binary()}) ::
          :ok | {:error, term()}
  def install(workdir, slug, intent_bytes, acceptance_files) do
    files =
      acceptance_files
      |> Stack.installed_files()
      |> Map.put(".kogen/intents/#{slug}/intent.md", intent_bytes)

    with :ok <- Workspace.insert_files(workdir, files),
         {:ok, _removed_path} <- remove_acceptance_source(workdir, slug) do
      :ok
    end
  end

  @spec remove_acceptance_source(Path.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def remove_acceptance_source(workdir, slug) do
    path = Path.join(workdir, Stack.acceptance_source(workdir, slug))

    case File.rm_rf(path) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, _removed} ->
        {:ok, Path.relative_to(path, workdir)}

      {:error, reason, failed_path} ->
        {:error, {:acceptance_source_cleanup_failed, failed_path, reason}}
    end
  end
end
