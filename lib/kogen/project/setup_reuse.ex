defmodule Kogen.Project.SetupReuse do
  @moduledoc false

  alias Kogen.Contracts.Project
  alias Kogen.Workspace

  @cache_version 1
  @max_entries 3
  @volatile_toolchain_env ~w(MISE_STATE_DIR MISE_CACHE_DIR MISE_TRUSTED_CONFIG_PATHS)
  @complete_file "complete"

  @type result :: %{key: String.t() | nil, reused?: boolean(), saved_wall_ms: non_neg_integer()}

  @spec run(
          Project.t(),
          Path.t(),
          Path.t() | nil,
          String.t() | nil,
          map(),
          (-> :ok | {:error, term()})
        ) :: {:ok, result()} | {:error, term()}
  def run(%Project{} = project, workdir, cache_root, base_tree_sha, toolchain_env, runner)
      when is_function(runner, 0) do
    if cacheable?(project, workdir, cache_root, base_tree_sha, toolchain_env) do
      key = cache_key(project, base_tree_sha, toolchain_env)
      run_cached(project, workdir, cache_root, key, runner)
    else
      run_uncached(runner)
    end
  end

  @spec record_reuse(Path.t(), result()) :: :ok | {:error, term()}
  def record_reuse(_run_dir, %{reused?: false}), do: :ok

  def record_reuse(run_dir, %{reused?: true, key: key, saved_wall_ms: wall_ms}) do
    line = ~s({"event":"setup_reused","setup_key":"#{key}","saved_wall_ms":#{wall_ms}}\n)
    path = Path.join(run_dir, "events.jsonl")

    with :ok <- File.mkdir_p(run_dir) do
      File.write(path, line, [:append, :binary])
    end
  end

  defp cacheable?(project, workdir, cache_root, base_tree_sha, toolchain_env) do
    project.setup != [] and project.setup_outputs != [] and safe_outputs?(project.setup_outputs) and
      absolute_directory?(workdir) and absolute_path?(cache_root) and valid_sha?(base_tree_sha) and
      is_map(toolchain_env)
  end

  defp run_cached(project, workdir, cache_root, key, runner) do
    entry = Path.join(cache_root, key)

    case restore(entry, key, project.setup_outputs, workdir) do
      {:hit, wall_ms} ->
        touch_entry(entry)
        trim(cache_root)
        {:ok, %{key: key, reused?: true, saved_wall_ms: wall_ms}}

      :miss ->
        run_and_publish(project.setup_outputs, workdir, cache_root, entry, key, runner)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_uncached(runner) do
    case runner.() do
      :ok -> {:ok, %{key: nil, reused?: false, saved_wall_ms: 0}}
      {:error, _reason} = error -> error
    end
  end

  defp run_and_publish(outputs, workdir, cache_root, entry, key, runner) do
    started_at = System.monotonic_time(:millisecond)

    case runner.() do
      :ok ->
        wall_ms = max(System.monotonic_time(:millisecond) - started_at, 0)
        _publish = publish(cache_root, entry, key, outputs, workdir, wall_ms)
        {:ok, %{key: key, reused?: false, saved_wall_ms: 0}}

      {:error, _reason} = error ->
        error
    end
  end

  defp restore(entry, key, outputs, workdir) do
    case read_entry(entry, key, outputs) do
      {:ok, metadata} ->
        case copy_outputs(entry, workdir, outputs, metadata.outputs) do
          :ok -> {:hit, metadata.setup_wall_ms}
          {:error, reason} -> restore_failure(workdir, outputs, reason)
        end

      :miss ->
        remove_invalid_entry(entry)
        :miss
    end
  end

  defp restore_failure(workdir, outputs, reason) do
    case remove_outputs(workdir, outputs) do
      :ok -> :miss
      {:error, cleanup_reason} -> {:error, {:setup_cache_cleanup_failed, reason, cleanup_reason}}
    end
  end

  defp publish(cache_root, entry, key, outputs, workdir, wall_ms) do
    with :ok <- File.mkdir_p(cache_root) do
      temporary = Path.join(cache_root, ".tmp-#{key}-#{System.unique_integer([:positive])}")

      case File.mkdir(temporary) do
        :ok -> publish_temporary(temporary, entry, key, outputs, workdir, wall_ms)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp publish_temporary(temporary, entry, key, outputs, workdir, wall_ms) do
    result =
      with {:ok, present} <- copy_present_outputs(workdir, temporary, outputs),
           :ok <- write_complete(temporary, key, wall_ms, present) do
        install_entry(temporary, entry, key, outputs)
      end

    _cleanup = File.rm_rf(temporary)
    if result == :ok, do: trim(Path.dirname(entry))
    result
  end

  defp copy_present_outputs(source_root, target_root, outputs) do
    present = Enum.filter(outputs, &path_exists?(Path.join(source_root, &1)))

    case copy_outputs(source_root, target_root, outputs, present) do
      :ok -> {:ok, present}
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_outputs(source_root, target_root, outputs, present) do
    with :ok <- remove_outputs(target_root, outputs) do
      Enum.reduce_while(present, :ok, fn relative, :ok ->
        source = Path.join(source_root, relative)
        destination = Path.join(target_root, relative)

        case Workspace.copy_on_write(source, destination) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:setup_cache_copy_failed, relative, reason}}}
        end
      end)
    end
  end

  defp remove_outputs(root, outputs) do
    Enum.reduce_while(outputs, :ok, fn relative, :ok ->
      case File.rm_rf(Path.join(root, relative)) do
        {:ok, _removed} -> {:cont, :ok}
        {:error, reason, path} -> {:halt, {:error, {reason, path}}}
      end
    end)
  end

  defp write_complete(directory, key, wall_ms, outputs) do
    write_metadata(directory, %{
      version: @cache_version,
      key: key,
      setup_wall_ms: wall_ms,
      outputs: outputs,
      last_used_ns: :erlang.system_time(:nanosecond)
    })
  end

  defp write_metadata(directory, metadata) do
    marker = Path.join(directory, @complete_file)
    temporary = marker <> ".#{System.unique_integer([:positive, :monotonic])}.tmp"
    contents = :erlang.term_to_binary(metadata, [:deterministic])

    with :ok <- File.write(temporary, contents, [:binary, :exclusive]),
         :ok <- File.rename(temporary, marker) do
      :ok
    else
      {:error, reason} ->
        _cleanup = File.rm(temporary)
        {:error, reason}
    end
  end

  defp install_entry(temporary, entry, key, outputs) do
    case File.rename(temporary, entry) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        case read_entry(entry, key, outputs) do
          {:ok, _metadata} -> :ok
          :miss -> error
        end
    end
  end

  defp read_entry(entry, key, declared_outputs) do
    case read_any_entry(entry) do
      {:ok, %{key: ^key, outputs: outputs} = metadata} ->
        if Enum.all?(outputs, &(&1 in declared_outputs)), do: {:ok, metadata}, else: :miss

      _invalid ->
        :miss
    end
  end

  defp decode_metadata(contents) do
    case :erlang.binary_to_term(contents, [:safe]) do
      %{
        version: @cache_version,
        key: key,
        setup_wall_ms: wall_ms,
        outputs: outputs,
        last_used_ns: last_used_ns
      }
      when is_binary(key) and is_integer(wall_ms) and wall_ms >= 0 and is_list(outputs) and
             is_integer(last_used_ns) ->
        if safe_outputs?(outputs) and length(outputs) == length(Enum.uniq(outputs)) do
          {:ok,
           %{
             version: @cache_version,
             key: key,
             setup_wall_ms: wall_ms,
             outputs: outputs,
             last_used_ns: last_used_ns
           }}
        else
          :error
        end

      _invalid ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp remove_invalid_entry(entry) do
    if File.dir?(entry), do: File.rm_rf(entry), else: :ok
  end

  defp touch_entry(entry) do
    case read_any_entry(entry) do
      {:ok, metadata} ->
        _update =
          write_metadata(entry, %{metadata | last_used_ns: :erlang.system_time(:nanosecond)})

      _missing ->
        :ok
    end

    :ok
  end

  defp trim(cache_root) do
    case File.ls(cache_root) do
      {:ok, names} ->
        entries = complete_entries(cache_root, names)
        Enum.each(Enum.drop(entries, @max_entries), fn {_mtime, path} -> File.rm_rf(path) end)
        remove_temporary_entries(cache_root, names)

      _missing ->
        :ok
    end
  end

  defp complete_entries(cache_root, names) do
    names
    |> Enum.map(&Path.join(cache_root, &1))
    |> Enum.flat_map(&complete_entry/1)
    |> Enum.sort_by(&elem(&1, 0), :desc)
  end

  defp complete_entry(path) do
    name = Path.basename(path)

    if Regex.match?(~r/\A[0-9a-f]{64}\z/, name) and File.dir?(path) do
      case read_any_entry(path) do
        {:ok, %{key: ^name, last_used_ns: last_used_ns}} -> [{last_used_ns, path}]
        _invalid -> []
      end
    else
      []
    end
  end

  defp read_any_entry(path) do
    case File.read(Path.join(path, @complete_file)) do
      {:ok, contents} -> decode_metadata(contents)
      {:error, _reason} -> :error
    end
  end

  defp remove_temporary_entries(cache_root, names) do
    names
    |> Enum.filter(&String.starts_with?(&1, ".tmp-"))
    |> Enum.each(&File.rm_rf(Path.join(cache_root, &1)))
  end

  defp cache_key(project, base_tree_sha, toolchain_env) do
    spec_hash = digest({project.setup, project.setup_outputs, project.env})
    toolchain_hash = toolchain_hash(toolchain_env)
    digest({@cache_version, base_tree_sha, spec_hash, toolchain_hash})
  end

  defp toolchain_hash(environment) do
    stable_environment = Map.drop(environment, @volatile_toolchain_env)

    digest({
      :os.type(),
      :erlang.system_info(:system_architecture),
      System.version(),
      System.otp_release(),
      stable_environment
    })
  end

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp safe_outputs?(outputs) when is_list(outputs) do
    Enum.all?(outputs, &safe_output?/1) and not overlapping_outputs?(outputs)
  end

  defp safe_outputs?(_outputs), do: false

  defp safe_output?(path) when is_binary(path) do
    parts = String.split(path, "/")

    path != "" and Path.type(path) == :relative and not String.contains?(path, <<0>>) and
      Enum.all?(parts, &(&1 not in ["", ".", "..", ".git"]))
  end

  defp safe_output?(_path), do: false

  defp overlapping_outputs?(outputs) do
    Enum.any?(outputs, fn parent ->
      Enum.any?(outputs, fn child ->
        parent != child and String.starts_with?(child, parent <> "/")
      end)
    end)
  end

  defp valid_sha?(sha) when is_binary(sha),
    do: Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, sha)

  defp valid_sha?(_sha), do: false

  defp path_exists?(path), do: match?({:ok, _stat}, File.lstat(path))

  defp absolute_path?(path), do: is_binary(path) and Path.type(path) == :absolute

  defp absolute_directory?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.dir?(path)
end
