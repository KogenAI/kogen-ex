defmodule Kogen.Workspace.Workspaces do
  @moduledoc false

  @spec root(Path.t(), Path.t()) :: Path.t()
  def root(project_root, home) do
    absolute_project = canonical(project_root)
    basename = absolute_project |> Path.basename() |> safe_basename()
    digest = :sha256 |> :crypto.hash(absolute_project) |> Base.encode16(case: :lower)

    Path.join([home, ".kogen", "workspaces", "#{basename}-#{binary_part(digest, 0, 10)}"])
  end

  @doc "The absolute project path with symlinks resolved; the key for per-project state."
  @spec canonical(Path.t()) :: Path.t()
  def canonical(project_root), do: project_root |> Path.expand() |> canonical_path()

  defp canonical_path(path) do
    ["/" | components] = Path.split(path)
    resolve_components(components, [], 0, path)
  end

  defp resolve_components([], resolved, _links, _fallback), do: Path.join(["/" | resolved])

  defp resolve_components([component | rest], resolved, links, fallback) do
    candidate = Path.join(["/" | resolved] ++ [component])

    case File.read_link(candidate) do
      {:ok, target} when links < 40 ->
        parent = Path.join(["/" | resolved])
        target = Path.expand(target, parent)
        ["/" | target_components] = Path.split(target)
        resolve_components(target_components ++ rest, [], links + 1, fallback)

      {:ok, _target} ->
        fallback

      {:error, _reason} ->
        resolve_components(rest, resolved ++ [component], links, fallback)
    end
  end

  defp safe_basename(name), do: Regex.replace(~r/[^A-Za-z0-9._-]+/, name, "-")
end
