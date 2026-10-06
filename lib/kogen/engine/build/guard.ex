defmodule Kogen.Engine.Build.Guard do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.Stack
  alias Kogen.Workspace

  @spec check(Path.t(), String.t(), Intent.t(), Project.t(), map(), map()) ::
          :ok | {:error, Failure.t()}
  def check(workdir, base_sha, _intent, _project, manifest, git_env) do
    case Workspace.protected_violations(workdir, base_sha, manifest, git_env) do
      {:ok, []} ->
        :ok

      {:ok, protected} ->
        failure(:protected_edit, "Protected paths changed: #{Enum.join(protected, ", ")}")

      {:error, reason} ->
        failure(
          :workspace_failed,
          "Cannot inspect protected paths: #{inspect(reason)}",
          :controller
        )
    end
  end

  @spec scope_warnings(Path.t(), String.t(), Intent.t(), Project.t(), map()) ::
          {:ok, [map()]} | {:error, Failure.t()}
  def scope_warnings(workdir, base_sha, intent, project, git_env) do
    case Workspace.changed_paths(workdir, base_sha, git_env) do
      {:ok, changed} ->
        prefixes =
          Enum.flat_map(intent.domains, &Map.get(project.domains, &1, [])) ++
            allowed_extra(intent, project.root)

        domains = Enum.sort(intent.domains)

        warnings =
          changed
          |> Enum.reject(&under_prefix?(&1, prefixes))
          |> Enum.sort()
          |> Enum.map(fn path ->
            %{
              path: path,
              declared_domains: domains,
              finding:
                "Scope warning: #{path} is outside the Intent's declared domains " <>
                  "[#{Enum.join(domains, ", ")}]."
            }
          end)

        {:ok, warnings}

      {:error, reason} ->
        failure(
          :workspace_failed,
          "Cannot inspect scope paths: #{inspect(reason)}",
          :controller
        )
    end
  end

  @spec tree_hash(Path.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def tree_hash(workdir, git_env), do: Workspace.tree_hash(workdir, git_env)

  defp under_prefix?(path, prefixes),
    do:
      Enum.any?(prefixes, fn prefix ->
        path == prefix or String.starts_with?(path, String.trim_trailing(prefix, "/") <> "/")
      end)

  defp allowed_extra(%Intent{slug: slug}, root),
    do: [
      ".kogen/intents/#{slug}"
      | [Stack.acceptance_source(root, slug), Stack.acceptance_test(root, slug)]
    ]

  defp failure(reason, detail, class \\ :candidate),
    do: {:error, %Failure{class: class, reason: reason, detail: detail}}
end
