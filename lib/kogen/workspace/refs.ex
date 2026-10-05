defmodule Kogen.Workspace.Refs do
  @moduledoc false

  alias Kogen.Workspace.Git

  @spec remote_url(Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, :missing | term()}
  def remote_url(repo, remote, git_env) when is_binary(remote) do
    case Git.run(repo, ["config", "--local", "--get", "remote.#{remote}.url"], git_env) do
      {:ok, 0, url} ->
        case Git.trim_line(url) do
          "" -> {:error, :missing}
          value -> {:ok, value}
        end

      {:ok, _status, _output} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec ref_read(Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, :missing | term()}
  def ref_read(repo, ref, git_env) do
    case Git.run(repo, ["show-ref", "--verify", "--hash", ref], git_env) do
      {:ok, 0, output} -> {:ok, Git.trim_line(output)}
      {:ok, _status, _output} -> {:error, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ref_create(Path.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, :exists | term()}
  def ref_create(repo, ref, sha, git_env) do
    with :ok <- validate_ref_and_sha(ref, sha),
         {:ok, 0, _output} <-
           Git.run(
             repo,
             ["update-ref", "--no-deref", "--stdin"],
             git_env,
             {:binary, "create #{ref} #{sha}\n"}
           ) do
      :ok
    else
      {:ok, _status, _output} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ref_update(Path.t(), String.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, :stale | term()}
  def ref_update(repo, ref, new_sha, old_sha, git_env) do
    compare_and_swap(
      repo,
      ["update-ref", "--no-deref", ref, new_sha, old_sha],
      ref,
      new_sha,
      old_sha,
      git_env
    )
  end

  @spec ref_delete(Path.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, :stale | term()}
  def ref_delete(repo, ref, expected_sha, git_env) do
    with :ok <- validate_ref_and_sha(ref, expected_sha) do
      case Git.run(repo, ["update-ref", "--no-deref", "-d", ref, expected_sha], git_env) do
        {:ok, 0, _output} -> :ok
        {:ok, _status, _output} -> {:error, :stale}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec commit_tree_with_files(
          Path.t(),
          %{String.t() => binary()},
          [String.t()],
          String.t(),
          %{String.t() => String.t()}
        ) :: {:ok, String.t()} | {:error, term()}
  def commit_tree_with_files(repo, files, parents, message, git_env) when is_map(files) do
    with :ok <- validate_files_and_parents(files, parents),
         true <- is_binary(message) and not String.contains?(message, <<0>>) do
      with_private_index(repo, git_env, fn index_env ->
        commit_with_private_index(repo, files, parents, message, index_env)
      end)
    else
      false -> {:error, :invalid_message}
      {:error, reason} -> {:error, reason}
    end
  end

  def commit_tree_with_files(_repo, _files, _parents, _message, _git_env),
    do: {:error, :invalid_files}

  @spec read_file_at(Path.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, binary()} | {:error, :missing | term()}
  def read_file_at(repo, rev, path, git_env) do
    if Git.safe_relative_path?(path) and valid_revision?(rev) do
      case Git.run(repo, ["cat-file", "blob", "#{rev}:#{path}"], git_env) do
        {:ok, 0, content} -> {:ok, content}
        {:ok, _status, _output} -> {:error, :missing}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing}
    end
  end

  @spec tree_paths(Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, [String.t()]} | {:error, term()}
  def tree_paths(repo, rev, git_env) do
    if valid_revision?(rev) do
      case Git.run(repo, ["ls-tree", "-r", "-z", "--name-only", rev], git_env) do
        {:ok, 0, output} -> {:ok, Git.nul_lines(output)}
        {:ok, status, output} -> {:error, {:ls_tree_failed, status, output}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_revision}
    end
  end

  @spec commit_message(Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, binary()} | {:error, term()}
  def commit_message(repo, rev, git_env) do
    case Git.run(repo, ["cat-file", "commit", rev], git_env) do
      {:ok, 0, commit} -> parse_commit_message(commit)
      {:ok, _status, _output} -> {:error, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rev_parse(Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, :missing | term()}
  def rev_parse(repo, rev, git_env) do
    if valid_revision?(rev) do
      case Git.run(
             repo,
             ["rev-parse", "--verify", "--quiet", "--end-of-options", "#{rev}^{object}"],
             git_env
           ) do
        {:ok, 0, sha} -> {:ok, Git.trim_line(sha)}
        {:ok, _status, _output} -> {:error, :missing}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing}
    end
  end

  @spec intent_commit(Path.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, String.t() | nil} | {:error, term()}
  def intent_commit(repo, revision, slug, git_env) do
    if valid_sha?(revision) and valid_intent_slug?(slug) do
      format = "%H%x00%(trailers:key=Kogen-Intent,valueonly)"
      grep = "^Kogen-Intent: #{slug}$"

      case Git.run(repo, ["log", "--grep=#{grep}", "--format=#{format}", revision], git_env) do
        {:ok, 0, output} -> intent_commit_from_log(output, slug)
        {:ok, _status, _output} -> {:error, :git_failed}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_intent_revision}
    end
  end

  defp intent_commit_from_log(output, slug) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, nil}, fn line, _result ->
      case String.split(line, <<0>>, parts: 2) do
        [sha, ^slug] when byte_size(sha) in [40, 64] ->
          if valid_sha?(sha), do: {:halt, {:ok, sha}}, else: {:cont, {:ok, nil}}

        _other ->
          {:cont, {:ok, nil}}
      end
    end)
  end

  @spec ancestor?(Path.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          boolean() | {:error, term()}
  def ancestor?(repo, a, b, git_env) do
    case Git.run(repo, ["merge-base", "--is-ancestor", a, b], git_env) do
      {:ok, 0, _output} -> true
      {:ok, _status, _output} -> false
      {:error, reason} -> {:error, reason}
    end
  end

  @spec compare_and_swap(
          Path.t(),
          [String.t()],
          String.t(),
          String.t(),
          String.t(),
          %{String.t() => String.t()}
        ) :: :ok | {:error, :stale | term()}
  defp compare_and_swap(repo, argv, ref, new_sha, old_sha, git_env) do
    with :ok <- validate_ref_and_sha(ref, new_sha),
         :ok <- validate_sha(old_sha) do
      case Git.run(repo, argv, git_env) do
        {:ok, 0, _output} -> :ok
        {:ok, _status, _output} -> {:error, :stale}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec validate_files_and_parents(%{String.t() => binary()}, [String.t()]) ::
          :ok | {:error, atom()}
  defp validate_files_and_parents(files, parents) when is_list(parents) do
    valid_files =
      Enum.all?(files, fn {path, content} ->
        Git.safe_relative_path?(path) and is_binary(content)
      end)

    if valid_files and Enum.all?(parents, &valid_sha?/1) do
      :ok
    else
      {:error, :invalid_files}
    end
  end

  defp validate_files_and_parents(_files, _parents), do: {:error, :invalid_parents}

  @spec commit_with_private_index(
          Path.t(),
          %{String.t() => binary()},
          [String.t()],
          String.t(),
          %{String.t() => String.t()}
        ) :: {:ok, String.t()} | {:error, term()}
  defp commit_with_private_index(repo, files, parents, message, index_env) do
    with :ok <- prepare_index(repo, parents, index_env),
         :ok <- insert_blobs(repo, files, index_env),
         {:ok, tree} <- git_ok(repo, ["write-tree"], index_env),
         {:ok, commit} <- write_commit(repo, Git.trim_line(tree), parents, message, index_env) do
      {:ok, Git.trim_line(commit)}
    end
  end

  @spec prepare_index(Path.t(), [String.t()], %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  defp prepare_index(repo, [], index_env),
    do: repo |> git_ok(["read-tree", "--empty"], index_env) |> to_ok()

  defp prepare_index(repo, [parent | _parents], index_env) do
    repo |> git_ok(["read-tree", "#{parent}^{tree}"], index_env) |> to_ok()
  end

  @spec insert_blobs(Path.t(), %{String.t() => binary()}, %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  defp insert_blobs(repo, files, index_env) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      case insert_blob(repo, path, content, index_env) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec insert_blob(Path.t(), String.t(), binary(), %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  defp insert_blob(repo, path, content, index_env) do
    with {:ok, blob_output} <-
           git_stdin(repo, ["hash-object", "-w", "--stdin"], content, index_env),
         blob = Git.trim_line(blob_output),
         {:ok, _output} <-
           git_ok(repo, ["update-index", "--add", "--cacheinfo", "100644", blob, path], index_env) do
      :ok
    end
  end

  @spec write_commit(Path.t(), String.t(), [String.t()], String.t(), %{String.t() => String.t()}) ::
          {:ok, binary()} | {:error, term()}
  defp write_commit(repo, tree, parents, message, git_env) do
    argv = ["commit-tree", tree] ++ Enum.flat_map(parents, &["-p", &1]) ++ ["-F", "-"]
    git_stdin(repo, argv, message, git_env)
  end

  @spec git_ok(Path.t(), [String.t()], %{String.t() => String.t()}) ::
          {:ok, binary()} | {:error, term()}
  defp git_ok(repo, argv, git_env) do
    case Git.status_ok(Git.run(repo, argv, git_env), :git_failed) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec git_stdin(Path.t(), [String.t()], binary(), %{String.t() => String.t()}) ::
          {:ok, binary()} | {:error, term()}
  defp git_stdin(repo, argv, input, git_env) do
    case Git.status_ok(Git.run(repo, argv, git_env, {:binary, input}), :git_failed) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec with_private_index(Path.t(), %{String.t() => String.t()}, (map() -> term())) :: term()
  defp with_private_index(repo, git_env, fun) do
    index_path = Git.private_index(repo)
    result = fun.(Git.private_environment(git_env, index_path))
    cleanup = Git.cleanup_index(index_path)

    case {result, cleanup} do
      {{:error, _reason} = error, :ok} -> error
      {{:ok, _value} = success, :ok} -> success
      {_result, {:error, reason}} -> {:error, reason}
    end
  end

  @spec to_ok({:ok, binary()} | {:error, term()}) :: :ok | {:error, term()}
  defp to_ok({:ok, _output}), do: :ok
  defp to_ok({:error, reason}), do: {:error, reason}

  @spec validate_ref_and_sha(String.t(), String.t()) :: :ok | {:error, atom()}
  defp validate_ref_and_sha(ref, sha) do
    with true <- is_binary(ref) and not String.contains?(ref, ["\n", "\r", " ", <<0>>]),
         :ok <- validate_sha(sha) do
      :ok
    else
      _other -> {:error, :invalid_ref}
    end
  end

  @spec validate_sha(String.t()) :: :ok | {:error, :invalid_sha}
  defp validate_sha(sha) do
    if valid_sha?(sha), do: :ok, else: {:error, :invalid_sha}
  end

  @spec valid_sha?(term()) :: boolean()
  defp valid_sha?(sha) when is_binary(sha),
    do: Regex.match?(~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/, sha)

  defp valid_sha?(_sha), do: false

  defp valid_intent_slug?(slug) when is_binary(slug),
    do: Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)

  defp valid_intent_slug?(_slug), do: false

  @spec valid_revision?(term()) :: boolean()
  defp valid_revision?(rev) when is_binary(rev),
    do: rev != "" and not String.contains?(rev, <<0>>)

  defp valid_revision?(_rev), do: false

  @spec parse_commit_message(binary()) :: {:ok, binary()} | {:error, :malformed_commit}
  defp parse_commit_message(commit) do
    case :binary.match(commit, "\n\n") do
      {position, 2} -> {:ok, binary_part(commit, position + 2, byte_size(commit) - position - 2)}
      :nomatch -> {:error, :malformed_commit}
    end
  end
end
