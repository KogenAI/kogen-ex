defmodule Kogen.Workspace.Guard do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.Stack
  alias Kogen.Workspace

  @absent_digest :sha256 |> :crypto.hash("kogen:absent") |> Base.encode16(case: :lower)

  @spec absent_digest() :: String.t()
  def absent_digest, do: @absent_digest

  @spec protected_violations(Path.t(), String.t(), %{String.t() => String.t()}, map()) ::
          {:ok, [String.t()]} | {:error, term()}
  def protected_violations(workdir, base_sha, manifest, git_env) do
    with {:ok, _changed} <- Workspace.changed_paths(workdir, base_sha, git_env),
         {:ok, mismatches} <- mismatched_paths(workdir, manifest) do
      {:ok, Enum.sort(mismatches)}
    end
  end

  @spec scope_violations(Path.t(), String.t(), Intent.t(), Project.t(), [String.t()], map()) ::
          {:ok, [String.t()]} | {:error, term()}
  def scope_violations(workdir, base_sha, intent, project, allowed_extra, git_env) do
    with {:ok, changed} <- Workspace.changed_paths(workdir, base_sha, git_env) do
      prefixes = Enum.flat_map(intent.domains, &Map.get(project.domains, &1, [])) ++ allowed_extra
      {:ok, Enum.reject(changed, &under_prefix?(&1, prefixes))}
    end
  end

  @spec check_candidate(Path.t(), String.t(), map(), map()) ::
          :ok | {:error, Failure.t()}
  def check_candidate(workdir, base_sha, manifest, git_env) do
    case protected_violations(workdir, base_sha, manifest, git_env) do
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
    case scope_violations(workdir, base_sha, intent, project, allowed_extra(intent, project.root), git_env) do
      {:ok, paths} ->
        domains = Enum.sort(intent.domains)

        warnings =
          paths
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

  defp mismatched_paths(workdir, manifest) do
    Enum.reduce_while(manifest, {:ok, []}, fn {path, approved_sha}, {:ok, mismatches} ->
      case matches?(workdir, path, approved_sha) do
        {:ok, true} -> {:cont, {:ok, mismatches}}
        {:ok, false} -> {:cont, {:ok, [path | mismatches]}}
        {:error, reason} -> {:halt, {:error, {:protected_unreadable, path, reason}}}
      end
    end)
  end

  defp matches?(workdir, path, approved_sha) do
    if safe_manifest_path?(path) do
      file_matches?(Path.join(workdir, path), approved_sha)
    else
      {:ok, false}
    end
  end

  # A removed or replaced file differs from the approved bytes unless the path was approved as
  # absent; any other read failure is unknown.
  defp file_matches?(full_path, approved_sha) do
    case File.read(full_path) do
      {:ok, contents} -> {:ok, sha256(contents) == approved_sha}
      {:error, reason} when reason in [:enoent, :enotdir] -> {:ok, approved_sha == @absent_digest}
      {:error, :eisdir} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sha256(contents), do: :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)

  defp safe_manifest_path?(path) do
    Path.type(path) == :relative and ".." not in Path.split(path) and path not in ["", "."]
  end

  defp under_prefix?(path, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, String.trim_trailing(prefix, "/") <> "/")
    end)
  end

  defp allowed_extra(%Intent{slug: slug}, root),
    do: [
      ".kogen/intents/#{slug}"
      | [Stack.acceptance_source(root, slug), Stack.acceptance_test(root, slug)]
    ]

  defp failure(reason, detail, class \\ :candidate),
    do: {:error, %Failure{class: class, reason: reason, detail: detail}}
end
