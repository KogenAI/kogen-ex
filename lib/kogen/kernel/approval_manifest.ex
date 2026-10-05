defmodule Kogen.Kernel.ApprovalManifest do
  @moduledoc false

  alias Kogen.Contracts.Project, as: ProjectData
  alias Kogen.Kernel.Approval.Request
  alias Kogen.Workspace

  @doc """
  Hashes the approved bytes of every protected path.

  Only the Intent's own files come from the project checkout. Every other protected path is
  hashed from the base tree in the origin at the approved base commit; a checkout whose copy of
  such a path differs from that tree is behind the base and the approval is refused.
  """
  @spec build(Request.t(), String.t(), map(), ProjectData.t(), binary(), %{String.t() => binary()}) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def build(%Request{} = request, base_sha, git_env, %ProjectData{} = project, intent, files) do
    source = %{
      project_root: request.project_root,
      origin: request.origin,
      base: request.base,
      base_sha: base_sha,
      git_env: git_env
    }

    own = own_files(request.slug, intent, files)
    acceptance_source = ".kogen/acceptance/#{request.slug}_test.exs"

    with {:ok, base_paths} <- Workspace.tree_paths(request.origin, base_sha, git_env),
         {:ok, tree_matches} <- glob_skeleton(base_paths, project.protected_paths),
         paths =
           candidate_paths(source, project.protected_paths, tree_matches, [
             acceptance_source | Map.keys(own)
           ]),
         {:ok, base_bytes} <- base_bytes(source, paths),
         :ok <- ensure_current(source, base_bytes) do
      {:ok, manifest(base_bytes, own)}
    end
  end

  defp own_files(slug, intent_bytes, acceptance_files) do
    %{
      ".kogen/intents/#{slug}/intent.md" => intent_bytes,
      "test/acceptance/#{slug}_test.exs" =>
        Map.fetch!(acceptance_files, ".kogen/acceptance/#{slug}_test.exs")
    }
  end

  defp candidate_paths(source, patterns, tree_matches, own_paths) do
    checkout_matches = Enum.flat_map(patterns, &expand(source.project_root, &1))

    (tree_matches ++ checkout_matches)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in own_paths))
    |> Enum.sort()
  end

  defp expand(root, pattern) do
    root
    |> Path.join(pattern)
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
  end

  # Evaluates the globs with the same semantics as the checkout by matching them against an
  # empty-file skeleton of the base tree.
  defp glob_skeleton(base_paths, patterns) do
    root = Path.join(System.tmp_dir!(), "kogen-approval-#{System.unique_integer([:positive])}")

    try do
      with :ok <- File.mkdir_p(root),
           :ok <- touch_all(root, base_paths) do
        {:ok, Enum.flat_map(patterns, &expand(root, &1))}
      else
        {:error, reason} -> {:error, {:base_tree_unavailable, reason}}
      end
    after
      File.rm_rf(root)
    end
  end

  defp touch_all(root, paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      target = Path.join(root, path)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(target, "") do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp base_bytes(source, paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, acc} ->
      case Workspace.read_file_at(source.origin, source.base_sha, path, source.git_env) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(acc, path, bytes)}}
        {:error, :missing} -> {:cont, {:ok, Map.put(acc, path, :missing)}}
        {:error, reason} -> {:halt, {:error, {:protected_file_unavailable, path, reason}}}
      end
    end)
  end

  defp ensure_current(source, base_bytes) do
    base_bytes
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {path, bytes}, {:ok, differing} ->
      case checkout_bytes(source.project_root, path) do
        {:ok, ^bytes} -> {:cont, {:ok, differing}}
        {:ok, _other} -> {:cont, {:ok, [path | differing]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> :ok
      {:ok, paths} -> {:error, {:checkout_behind_base, source.base, Enum.reverse(paths)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp checkout_bytes(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} when reason in [:enoent, :eisdir, :enotdir] -> {:ok, :missing}
      {:error, reason} -> {:error, {:protected_file_unavailable, path, reason}}
    end
  end

  defp manifest(base_bytes, own) do
    base_bytes
    |> Enum.reject(fn {_path, bytes} -> bytes == :missing end)
    |> Map.new()
    |> Map.merge(own)
    |> Map.new(fn {path, bytes} -> {path, sha256(bytes)} end)
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
