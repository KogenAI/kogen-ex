defmodule Kogen.Proc.Sandbox do
  @moduledoc """
  Seatbelt policy inputs for commands that execute Candidate code.

  macOS uses `sandbox-exec`. Linux remains unrestricted until a bubblewrap policy is designed.
  """

  @marker "KOGEN_SANDBOXED"

  @enforce_keys [:enabled, :home, :project_root, :origin, :workspace, :run_dir, :tmp_dir]
  defstruct @enforce_keys ++ [workspace_is_project: false]

  @type t :: %__MODULE__{
          enabled: boolean(),
          home: Path.t(),
          project_root: Path.t(),
          origin: Path.t(),
          workspace: Path.t(),
          run_dir: Path.t(),
          tmp_dir: Path.t(),
          workspace_is_project: boolean()
        }

  @spec command([String.t()], t() | nil) ::
          {:ok, [String.t()]} | {:error, term()}
  # macOS cannot nest Seatbelt profiles: inside Kogen's own sandbox (KOGEN_SANDBOXED=1 in the
  # OS environment) applying another fails with `sandbox_apply: Operation not permitted`, and
  # the outer sandbox already confines this process and everything it spawns. So wrapping is
  # a no-op there.
  def command(argv, sandbox) do
    if nested?(), do: {:ok, argv}, else: confine(argv, sandbox)
  end

  @doc """
  Environment every child must carry: callers build explicit child environments that would
  otherwise drop the marker and let a nested Kogen try to wrap again.
  """
  @spec child_env() :: %{optional(String.t()) => String.t()}
  def child_env, do: if(nested?(), do: Map.new([{@marker, "1"}]), else: %{})

  defp nested?, do: System.get_env(@marker) == "1"

  defp confine(argv, %__MODULE__{enabled: true} = sandbox) do
    case :os.type() do
      {:unix, :darwin} ->
        wrap(argv, sandbox)

      # TODO(linux): implement equivalent confinement with bubblewrap.
      _other ->
        {:ok, argv}
    end
  end

  defp confine(argv, _disabled_or_missing), do: {:ok, argv}

  defp wrap(argv, sandbox) do
    with {:ok, generated_profile} <- profile(sandbox) do
      # Mark children so a nested Kogen skips its own sandbox: macOS forbids nesting.
      {:ok,
       ["/usr/bin/sandbox-exec", "-p", generated_profile, "/usr/bin/env", "KOGEN_SANDBOXED=1"] ++
         argv}
    end
  end

  @spec profile(t()) :: {:ok, String.t()} | {:error, term()}
  def profile(%__MODULE__{} = sandbox) do
    with {:ok, home} <- canonical_path(sandbox.home),
         {:ok, writable} <- writable_paths(sandbox, home),
         {:ok, protected} <- canonical_paths(credential_paths(home)),
         {:ok, project} <- canonical_path(sandbox.project_root),
         {:ok, origin} <- canonical_path(sandbox.origin),
         {:ok, workspace} <- canonical_path(sandbox.workspace) do
      protected_roots =
        [project, origin]
        |> Enum.uniq()
        |> Enum.reject(&(sandbox.workspace_is_project and &1 == workspace))

      rules =
        [
          "(version 1)",
          "(allow default)",
          "(deny file-write*)",
          "(allow file-write-data (literal \"/dev/null\"))"
        ] ++
          Enum.map(writable, &allow_subpath(:file_write, &1)) ++
          Enum.map(protected, &deny_subpath(:file_read, &1)) ++
          [
            deny_credential_pattern(:file_read, home),
            deny_credential_pattern(:file_write, home)
          ] ++
          Enum.map(protected, &deny_subpath(:file_write, &1)) ++
          Enum.map(protected_roots, &deny_subpath(:file_write, &1))

      {:ok, Enum.join(rules, "\n")}
    end
  end

  defp writable_paths(sandbox, home) do
    paths =
      [sandbox.workspace, sandbox.run_dir, sandbox.tmp_dir, shared_tmp()] ++
        cache_paths(home)

    canonical_paths(paths)
  end

  # Test suites write fixed paths under /tmp (screenshots, sockets); the project and
  # origin stay denied because their deny rules follow the allows.
  defp shared_tmp, do: "/tmp"

  defp canonical_paths(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, resolved} ->
      case canonical_path(path) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | resolved]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  defp cache_paths(home) do
    [
      Path.join([home, ".cache", "mise"]),
      Path.join(home, ".hex"),
      Path.join([home, ".cache", "rebar3"]),
      Path.join(home, ".npm")
    ]
  end

  defp credential_paths(home) do
    [
      Path.join(home, ".codex"),
      Path.join(home, ".ssh"),
      Path.join(home, ".gnupg"),
      Path.join([home, "Library", "Keychains"])
    ]
  end

  defp deny_credential_pattern(operation, home) do
    pattern = "^" <> sbpl_regex_literal(home) <> "/[.]kogen/credentials[^/]*(/.*)?$"
    "(deny #{operation_name(operation)} (regex ##{sbpl_string(pattern)}))"
  end

  # SBPL regexes are POSIX-style; bracket each metacharacter instead of backslash-escaping it.
  defp sbpl_regex_literal(path) do
    path
    |> String.graphemes()
    |> Enum.map_join(fn char ->
      if String.contains?(".*+?()[]{}|$^", char), do: "[" <> char <> "]", else: char
    end)
  end

  defp allow_subpath(operation, path),
    do: "(allow #{operation_name(operation)} (subpath #{sbpl_string(path)}))"

  defp deny_subpath(operation, path),
    do: "(deny #{operation_name(operation)} (subpath #{sbpl_string(path)}))"

  defp operation_name(:file_read), do: "file-read*"
  defp operation_name(:file_write), do: "file-write*"

  defp sbpl_string(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end

  defp canonical_path(path) when is_binary(path), do: canonical_path(Path.expand(path), 0)

  defp canonical_path(_path), do: {:error, :invalid_sandbox_path}

  defp canonical_path(_path, depth) when depth >= 40, do: {:error, :sandbox_path_symlink_loop}

  defp canonical_path(path, depth) do
    path
    |> Path.split()
    |> canonical_components("/", depth)
  end

  defp canonical_components([], current, _depth), do: {:ok, current}

  defp canonical_components(["/" | rest], _current, depth),
    do: canonical_components(rest, "/", depth)

  defp canonical_components([segment | rest], current, depth) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} -> resolve_link(candidate, rest, depth)
      {:ok, _stat} -> canonical_components(rest, candidate, depth)
      {:error, :enoent} -> {:ok, append_segments(current, [segment | rest])}
      {:error, reason} -> {:error, {:sandbox_path_unavailable, candidate, reason}}
    end
  end

  defp resolve_link(link, rest, depth) do
    case File.read_link(link) do
      {:ok, target} ->
        target = Path.expand(target, Path.dirname(link))

        with {:ok, resolved} <- canonical_path(target, depth + 1) do
          canonical_components(rest, resolved, depth + 1)
        end

      {:error, reason} ->
        {:error, {:sandbox_path_unavailable, link, reason}}
    end
  end

  defp append_segments(path, segments),
    do: Enum.reduce(segments, path, fn segment, current -> Path.join(current, segment) end)
end
