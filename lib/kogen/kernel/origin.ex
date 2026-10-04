defmodule Kogen.Kernel.Origin do
  @moduledoc false

  @spec resolve(Path.t(), Path.t() | nil, %{String.t() => String.t()}) ::
          {:ok, Path.t()} | {:error, term()}
  def resolve(_project_root, origin, _git_env) when is_binary(origin), do: {:ok, origin}

  def resolve(project_root, nil, git_env) do
    case local_origin(project_root, git_env) do
      {:ok, path} -> {:ok, path}
      {:error, _reason} -> {:ok, project_root}
    end
  end

  defp local_origin(project_root, git_env) do
    with {:ok, remote} <- Kogen.Workspace.remote_url(project_root, "origin", git_env),
         {:ok, path} <- local_origin_path(remote, project_root),
         true <- local_git_repository?(path) do
      {:ok, path}
    else
      _other -> {:error, :no_local_origin}
    end
  end

  defp local_origin_path("file://" <> _rest = remote, project_root) do
    case URI.parse(remote) do
      %URI{host: host, path: path} when host in [nil, "", "localhost"] and is_binary(path) ->
        {:ok, Path.expand(path, project_root)}

      _other ->
        {:error, :non_local_origin}
    end
  rescue
    ArgumentError -> {:error, :invalid_origin}
  end

  defp local_origin_path(remote, project_root) do
    remote_scheme? =
      String.contains?(remote, "://") or
        Regex.match?(~r/\A[A-Za-z][A-Za-z0-9+.-]*:/, remote)

    scp_remote? = Regex.match?(~r/\A[^\/:]+@[^:]+:/, remote)

    if remote_scheme? or scp_remote? do
      {:error, :non_local_origin}
    else
      remote = if String.starts_with?(remote, "~/"), do: expand_home(remote), else: remote
      {:ok, Path.expand(remote, project_root)}
    end
  end

  defp expand_home("~/" <> rest) do
    case Kogen.Kernel.RuntimeDiscovery.home() do
      {:ok, home} -> Path.join(home, rest)
      {:error, _reason} -> "~/" <> rest
    end
  end

  defp local_git_repository?(path) do
    File.dir?(path) and
      (File.exists?(Path.join(path, "HEAD")) or File.exists?(Path.join(path, ".git")))
  end
end
