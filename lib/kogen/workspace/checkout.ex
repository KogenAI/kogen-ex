defmodule Kogen.Workspace.Checkout do
  @moduledoc false

  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Stack
  alias Kogen.Workspace.Git

  @spec create(Path.t(), String.t(), Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, %{path: Path.t(), base_sha: String.t()}} | {:error, term()}
  @spec create(
          Path.t(),
          String.t(),
          Path.t(),
          String.t(),
          %{String.t() => String.t()},
          keyword()
        ) :: {:ok, %{path: Path.t(), base_sha: String.t()}} | {:error, term()}
  def create(origin, base_sha, root, build_id, git_env, options \\ []) do
    with {:ok, seed_from} <- seed_source(origin, options),
         :ok <- validate_create(origin, root, build_id),
         :ok <- File.mkdir_p(root),
         :ok <- ensure_destination_absent(Path.join(root, build_id)),
         :ok <- clone(origin, root, build_id, git_env) do
      finish_create(Path.join(root, build_id), seed_from, base_sha, git_env)
    end
  end

  @spec insert_files(Path.t(), %{String.t() => binary()}) :: :ok | {:error, term()}
  def insert_files(path, files) when is_map(files) do
    with true <- Git.valid_worktree_path?(path),
         :ok <- validate_file_map(files) do
      Enum.reduce_while(files, :ok, fn {relative_path, content}, :ok ->
        case write_inserted_file(path, relative_path, content) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      false -> {:error, :invalid_path}
      {:error, reason} -> {:error, reason}
    end
  end

  def insert_files(_path, _files), do: {:error, :invalid_files}

  @spec tree_hash(Path.t(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, term()}
  def tree_hash(path, git_env) do
    with_private_index(path, git_env, fn index_env ->
      with {:ok, _output} <- git_ok(path, ["read-tree", "HEAD"], index_env),
           {:ok, _output} <- git_ok(path, ["add", "-A", "--", "."], index_env),
           {:ok, output} <- git_ok(path, ["write-tree"], index_env) do
        {:ok, Git.trim_line(output)}
      end
    end)
  end

  @spec changed_paths(Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, [String.t()]} | {:error, term()}
  def changed_paths(path, base_sha, git_env) do
    with {:ok, tree} <- tree_hash(path, git_env),
         {:ok, output} <-
           git_ok(path, ["diff", "--no-renames", "--name-only", "-z", base_sha, tree], git_env) do
      {:ok, Git.nul_lines(output)}
    end
  end

  @spec commit(Path.t(), String.t(), [{String.t(), String.t()}], %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, term()}
  def commit(path, message, trailers, git_env) do
    with :ok <- validate_commit(message, trailers),
         {:ok, _output} <- git_ok(path, ["add", "-A", "--", "."], git_env),
         {:ok, _output} <-
           git_stdin(
             path,
             ["commit", "--no-verify", "--file=-"],
             message_with_trailers(message, trailers),
             git_env
           ),
         {:ok, sha} <- git_ok(path, ["rev-parse", "--verify", "HEAD"], git_env) do
      {:ok, Git.trim_line(sha)}
    end
  end

  @spec commit_paths(Path.t(), String.t(), [String.t()], [{String.t(), String.t()}], %{
          String.t() => String.t()
        }) :: {:ok, String.t()} | {:error, term()}
  def commit_paths(path, message, paths, trailers, git_env) do
    with :ok <- validate_commit(message, trailers),
         :ok <- validate_commit_paths(paths),
         {:ok, _output} <- git_ok(path, ["add", "-A", "--" | paths], git_env),
         {:ok, _output} <-
           git_stdin(
             path,
             ["commit", "--only", "--no-verify", "--file=-" | ["--" | paths]],
             message_with_trailers(message, trailers),
             git_env
           ),
         {:ok, sha} <- git_ok(path, ["rev-parse", "--verify", "HEAD"], git_env) do
      {:ok, Git.trim_line(sha)}
    end
  end

  @spec reset_soft(Path.t(), String.t(), %{String.t() => String.t()}) :: :ok | {:error, term()}
  def reset_soft(path, base_sha, git_env) do
    run_base_command(path, base_sha, ["reset", "--soft", base_sha], git_env)
  end

  @spec run_base_command(Path.t(), String.t(), [String.t()], %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  defp run_base_command(path, base_sha, argv, git_env) do
    if Git.valid_worktree_path?(path) and valid_sha?(base_sha) do
      case Git.run(path, argv, git_env) do
        {:ok, 0, _output} -> :ok
        {:ok, status, _output} -> {:error, {:git_failed, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_rebase}
    end
  end

  @spec destroy(Path.t()) :: :ok | {:error, term()}
  def destroy(path) do
    if destroyable_path?(path) do
      case File.rm_rf(path) do
        {:ok, _removed} -> :ok
        {:error, reason, _path} -> {:error, reason}
      end
    else
      {:error, :invalid_path}
    end
  end

  @spec destroyable_path?(Path.t()) :: boolean()
  defp destroyable_path?(path) do
    Git.valid_worktree_path?(path) or legacy_worktree_path?(path)
  end

  @spec legacy_worktree_path?(Path.t()) :: boolean()
  defp legacy_worktree_path?(path) when is_binary(path) do
    parts = Path.split(Path.expand(path))

    Path.type(path) == :absolute and Path.expand(path) == path and
      match?([".kogen", "w", build_id] when build_id != "", Enum.take(parts, -3)) and
      Git.safe_build_id?(Path.basename(path))
  end

  defp legacy_worktree_path?(_path), do: false

  @spec validate_create(Path.t(), Path.t(), String.t()) :: :ok | {:error, atom()}
  defp validate_create(origin, root, build_id) do
    if absolute_directory?(origin) and valid_workspace_root?(root) and
         Git.safe_build_id?(build_id) do
      :ok
    else
      {:error, :invalid_path}
    end
  end

  @spec absolute_directory?(Path.t()) :: boolean()
  defp absolute_directory?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.dir?(path)

  @spec valid_workspace_root?(Path.t()) :: boolean()
  defp valid_workspace_root?(path) when is_binary(path) do
    parts = Path.split(Path.expand(path))

    Path.type(path) == :absolute and
      match?([".kogen", "workspaces", key] when key != "", Enum.take(parts, -3))
  end

  defp valid_workspace_root?(_path), do: false

  @spec ensure_destination_absent(Path.t()) :: :ok | {:error, :exists}
  defp ensure_destination_absent(path) do
    if File.exists?(path), do: {:error, :exists}, else: :ok
  end

  @spec clone(Path.t(), Path.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  defp clone(origin, root, build_id, git_env) do
    destination = Path.join(root, build_id)

    case Git.run(
           root,
           [
             "clone",
             "--local",
             "--no-hardlinks",
             "--no-checkout",
             "--template=",
             origin,
             destination
           ],
           git_env
         ) do
      {:ok, 0, _output} -> :ok
      {:ok, _status, _output} -> cleanup_failed_clone(destination, :clone_failed)
      {:error, reason} -> cleanup_failed_clone(destination, reason)
    end
  end

  @spec cleanup_failed_clone(Path.t(), term()) :: {:error, term()}
  defp cleanup_failed_clone(destination, reason) do
    case remove_seed(destination) do
      :ok -> {:error, reason}
      {:error, _cleanup_reason} -> {:error, :cleanup_failed}
    end
  end

  @spec finish_create(Path.t(), Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, %{path: Path.t(), base_sha: String.t()}} | {:error, term()}
  defp finish_create(path, seed_from, base_sha, git_env) do
    with {:ok, _output} <- git_ok(path, ["checkout", "--detach", base_sha], git_env),
         {:ok, head} <- git_ok(path, ["rev-parse", "--verify", "HEAD"], git_env),
         :ok <- seed(path, seed_from, git_env) do
      {:ok, %{path: path, base_sha: Git.trim_line(head)}}
    else
      {:error, reason} -> cleanup_failed_create(path, reason)
    end
  end

  @spec cleanup_failed_create(Path.t(), term()) :: {:error, term()}
  defp cleanup_failed_create(path, reason) do
    case destroy(path) do
      :ok -> {:error, reason}
      {:error, _cleanup_reason} -> {:error, :cleanup_failed}
    end
  end

  @spec seed(Path.t(), Path.t(), %{String.t() => String.t()}) :: :ok | {:error, term()}
  defp seed(destination, origin, git_env) do
    Enum.reduce_while(Stack.seed_dirs(Stack.detect(destination)), :ok, fn directory, :ok ->
      case seed_directory(destination, origin, directory, git_env) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec seed_source(Path.t(), keyword()) :: {:ok, Path.t()} | {:error, atom()}
  defp seed_source(origin, options) do
    if Keyword.keyword?(options) and Keyword.keys(options) -- [:seed_from] == [] do
      source = Keyword.get(options, :seed_from, origin)

      if absolute_directory?(source), do: {:ok, source}, else: {:error, :invalid_seed_source}
    else
      {:error, :invalid_options}
    end
  end

  @spec seed_directory(Path.t(), Path.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  defp seed_directory(destination, origin, directory, git_env) do
    source = Path.join(origin, directory)
    target_parent = Path.join(destination, Path.dirname(directory))
    File.mkdir_p!(target_parent)

    if File.dir?(source) and not File.exists?(Path.join(destination, directory)) do
      case copy_with_clonefile(source, target_parent, git_env) do
        :ok -> :ok
        {:error, _reason} -> copy_plain(source, target_parent, Path.basename(directory), git_env)
      end
    else
      :ok
    end
  end

  @spec copy_with_clonefile(Path.t(), Path.t(), %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  defp copy_with_clonefile(source, destination, git_env) do
    case run_copy(["cp", "-c", "-R", source, destination <> "/"], destination, git_env) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        case remove_seed(Path.join(destination, Path.basename(source))) do
          :ok -> error
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec copy_plain(Path.t(), Path.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  defp copy_plain(source, destination, directory, git_env) do
    with :ok <- remove_seed(Path.join(destination, directory)),
         :ok <- run_copy(["cp", "-R", source, destination <> "/"], destination, git_env) do
      :ok
    else
      {:error, _reason} -> {:error, :seed_failed}
    end
  end

  @spec run_copy([String.t()], Path.t(), %{String.t() => String.t()}) :: :ok | {:error, term()}
  defp run_copy(argv, directory, git_env) do
    case Kogen.Workspace.Process.run(argv, cd: directory, env: git_env) do
      {:ok, %ProcResult{exit_status: 0, timed_out: false}} -> :ok
      {:ok, %ProcResult{timed_out: true}} -> {:error, :timeout}
      {:ok, %ProcResult{}} -> {:error, :copy_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec remove_seed(Path.t()) :: :ok | {:error, term()}
  defp remove_seed(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  @spec write_inserted_file(Path.t(), String.t(), binary()) :: :ok | {:error, term()}
  defp write_inserted_file(root, relative_path, content) do
    destination = Path.join(root, relative_path)

    with :ok <- File.mkdir_p(Path.dirname(destination)) do
      File.write(destination, content, [:binary])
    end
  end

  @spec validate_file_map(%{String.t() => binary()}) :: :ok | {:error, :invalid_files}
  defp validate_file_map(files) do
    if Enum.all?(files, fn {path, content} ->
         Git.safe_relative_path?(path) and is_binary(content)
       end) do
      :ok
    else
      {:error, :invalid_files}
    end
  end

  @spec validate_commit(String.t(), [{String.t(), String.t()}]) :: :ok | {:error, atom()}
  defp validate_commit(message, trailers) when is_binary(message) and is_list(trailers) do
    valid_message = not String.contains?(message, <<0>>)

    valid_trailers =
      Enum.all?(trailers, fn {key, value} ->
        is_binary(key) and Regex.match?(~r/\A[A-Za-z0-9-]+\z/, key) and is_binary(value) and
          not String.contains?(value, ["\n", "\r", <<0>>])
      end)

    if valid_message and valid_trailers, do: :ok, else: {:error, :invalid_commit_message}
  end

  defp validate_commit(_message, _trailers), do: {:error, :invalid_commit_message}

  defp validate_commit_paths(paths) when is_list(paths) and paths != [] do
    if Enum.all?(paths, &Git.safe_relative_path?/1), do: :ok, else: {:error, :invalid_paths}
  end

  defp validate_commit_paths(_paths), do: {:error, :invalid_paths}

  @spec valid_sha?(String.t()) :: boolean()
  @doc false
  @spec valid_sha?(String.t()) :: boolean()
  def valid_sha?(sha), do: Regex.match?(~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/, sha)

  @spec message_with_trailers(String.t(), [{String.t(), String.t()}]) :: binary()
  defp message_with_trailers(message, []), do: String.trim_trailing(message, "\n") <> "\n"

  defp message_with_trailers(message, trailers) do
    rendered = Enum.map_join(trailers, "\n", fn {key, value} -> "#{key}: #{value}" end)
    String.trim_trailing(message, "\n") <> "\n\n" <> rendered <> "\n"
  end

  @spec git_ok(Path.t(), [String.t()], %{String.t() => String.t()}) ::
          {:ok, binary()} | {:error, term()}
  defp git_ok(path, argv, git_env) do
    case Git.status_ok(Git.run(path, argv, git_env), :git_failed) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec git_stdin(Path.t(), [String.t()], binary(), %{String.t() => String.t()}) ::
          {:ok, binary()} | {:error, term()}
  defp git_stdin(path, argv, input, git_env) do
    case Git.status_ok(Git.run(path, argv, git_env, {:binary, input}), :git_failed) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec with_private_index(Path.t(), %{String.t() => String.t()}, (map() -> term())) :: term()
  def with_private_index(path, git_env, fun) do
    index_path = Git.private_index(path)
    result = fun.(Git.private_environment(git_env, index_path))
    cleanup = Git.cleanup_index(index_path)

    case {result, cleanup} do
      {{:error, _reason} = error, :ok} -> error
      {{:ok, _value} = success, :ok} -> success
      {_result, {:error, reason}} -> {:error, reason}
    end
  end
end
