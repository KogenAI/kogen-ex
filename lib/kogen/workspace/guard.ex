defmodule Kogen.Workspace.Guard do
  @moduledoc false

  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Project
  alias Kogen.Workspace

  @spec protected_violations(Path.t(), String.t(), %{String.t() => String.t()}, map()) ::
          {:ok, [String.t()]} | {:error, term()}
  def protected_violations(workdir, base_sha, manifest, git_env) do
    with {:ok, _changed} <- Workspace.changed_paths(workdir, base_sha, git_env) do
      mismatches =
        Enum.filter(manifest, fn {path, approved_sha} ->
          not safe_manifest_path?(path) or file_sha(workdir, path) != approved_sha
        end)

      {:ok, mismatches |> Enum.map(&elem(&1, 0)) |> Enum.sort()}
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

  defp file_sha(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, contents} -> :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)
      {:error, _reason} -> nil
    end
  end

  defp safe_manifest_path?(path) do
    Path.type(path) == :relative and ".." not in Path.split(path) and path not in ["", "."]
  end

  defp under_prefix?(path, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, String.trim_trailing(prefix, "/") <> "/")
    end)
  end
end
