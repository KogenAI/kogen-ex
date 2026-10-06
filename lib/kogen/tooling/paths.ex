defmodule Kogen.Tooling.Paths do
  @moduledoc false

  alias Kogen.Tooling.Context
  alias Kogen.Tooling.Error

  @max_links 40

  @spec safe(Context.t(), String.t()) :: {:ok, Path.t(), Path.t()} | {:error, Error.t()}
  def safe(%Context{} = opts, requested_path) when is_binary(requested_path) do
    with true <- Path.type(opts.workdir) == :absolute,
         root = Path.expand(opts.workdir),
         requested = Path.expand(requested_path, root),
         {:ok, canonical_root} <- canonical(root, 0),
         {:ok, canonical_path} <- canonical(requested, 0),
         :ok <- inside_root(canonical_root, canonical_path) do
      {:ok, canonical_path, Path.relative_to(canonical_path, canonical_root)}
    else
      false -> error(:invalid_workdir, "Worktree path must be absolute.")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def safe(_opts, _requested_path), do: error(:invalid_path, "Path must be a string.")

  @spec run_dir(Context.t()) :: {:ok, Path.t()} | {:error, Error.t()}
  def run_dir(%Context{} = opts) do
    with true <- Path.type(opts.workdir) == :absolute and Path.type(opts.run_dir) == :absolute,
         root = Path.expand(opts.workdir),
         requested = Path.expand(opts.run_dir),
         {:ok, canonical_root} <- canonical(root, 0),
         {:ok, canonical_run_dir} <- canonical(requested, 0),
         :ok <- outside_candidate(canonical_root, canonical_run_dir) do
      {:ok, canonical_run_dir}
    else
      false -> error(:invalid_run_dir, "Worktree and run directory paths must be absolute.")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec log_file(Context.t(), String.t()) :: {:ok, Path.t()} | {:error, Error.t()}
  def log_file(opts, name) do
    with true <- Path.basename(name) == name,
         {:ok, run} <- run_dir(opts),
         {:ok, logs} <- canonical(Path.join(run, "logs"), 0),
         :ok <- inside_root(run, logs),
         {:ok, path} <- canonical(Path.join(logs, name), 0),
         :ok <- inside_root(logs, path) do
      {:ok, path}
    else
      false -> error(:invalid_log_handle, "Log handle must name a retained result.")
      {:error, error} -> {:error, error}
    end
  end

  defp canonical(_path, depth) when depth > @max_links,
    do: error(:symlink_loop, "Path contains too many symbolic links.")

  defp canonical(path, depth) do
    path = Path.expand(path)
    ["/" | segments] = Path.split(path)
    canonical_segments("/", segments, depth)
  end

  defp canonical_segments(current, [], _depth), do: {:ok, Path.expand(current)}

  defp canonical_segments(current, [segment | rest], depth) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        follow_link(candidate, rest, depth)

      {:ok, _stat} ->
        canonical_segments(candidate, rest, depth)

      {:error, :enoent} ->
        missing_tail(candidate, rest)

      {:error, reason} ->
        error(:path_unavailable, "Cannot inspect path component: #{inspect(reason)}")
    end
  end

  defp follow_link(candidate, rest, depth) do
    case File.read_link(candidate) do
      {:ok, target} ->
        target = Path.expand(target, Path.dirname(candidate))
        combined = if rest == [], do: target, else: Path.join(target, Path.join(rest))
        canonical(combined, depth + 1)

      {:error, reason} ->
        error(:path_unavailable, "Cannot resolve symbolic link: #{inspect(reason)}")
    end
  end

  defp missing_tail(candidate, rest) do
    tail = if rest == [], do: candidate, else: Path.join(candidate, Path.join(rest))
    {:ok, Path.expand(tail)}
  end

  defp inside_root(root, path) do
    if path == root or String.starts_with?(path, root <> "/"),
      do: :ok,
      else: error(:path_escape, "Path escapes the worktree.")
  end

  defp outside_candidate(root, path) do
    if path == root or String.starts_with?(path, root <> "/"),
      do:
        error(:run_dir_inside_candidate, "Run logs and transcripts must be outside the worktree."),
      else: :ok
  end

  defp error(reason, detail), do: {:error, %Error{reason: reason, detail: detail}}
end
