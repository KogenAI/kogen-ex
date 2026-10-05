defmodule Kogen.Engine.Runtime do
  @moduledoc false

  alias Kogen.Contracts.MiseEnvironment

  @output_tail_bytes 2_048

  @enforce_keys [:base_env, :git_env, :mise]
  defstruct [:base_env, :git_env, :mise, sandboxed: false]

  @type t :: %__MODULE__{
          base_env: %{String.t() => String.t()},
          git_env: %{String.t() => String.t()},
          mise: Path.t(),
          sandboxed: boolean()
        }

  @base_keys ~w(PATH HOME LANG LC_ALL TERM TMPDIR USER SHELL MIX_HOME HEX_HOME https_proxy HTTPS_PROXY all_proxy ALL_PROXY http_proxy HTTP_PROXY no_proxy NO_PROXY)

  @spec new(map(), Path.t(), Path.t() | nil, Path.t(), Path.t()) :: t()
  def new(system_env, mise, script_path, ert_dir, ert_bin) do
    env = selected_environment(system_env)
    markers = runtime_markers(script_path, ert_dir, ert_bin)
    base_env = Map.merge(env, markers)

    %__MODULE__{
      base_env: base_env,
      git_env: git_environment(base_env),
      mise: mise,
      sandboxed: Map.get(system_env, "KOGEN_SANDBOXED") == "1"
    }
  end

  @spec process_env(t(), map()) :: %{String.t() => String.t()}
  def process_env(%__MODULE__{} = runtime, toolchain_env) do
    runtime.base_env
    |> Map.merge(toolchain_env)
    |> include_mise_binary(runtime.mise)
    |> Map.merge(runtime_markers_from(runtime.base_env))
  end

  @doc "Trusts the mise config of one workspace path through the environment only."
  @spec trust_workspace(t() | map(), Path.t()) :: t() | map()
  def trust_workspace(%__MODULE__{} = runtime, path) when is_binary(path) do
    %{runtime | base_env: trust_workspace(runtime.base_env, path)}
  end

  def trust_workspace(env, path) when is_map(env) and is_binary(path) do
    MiseEnvironment.trust_workspace(env, path)
  end

  @doc "Adds one workspace to mise's trusted config paths through the environment only."
  @spec add_trusted_workspace(t() | map(), Path.t()) :: t() | map()
  def add_trusted_workspace(%__MODULE__{} = runtime, path) when is_binary(path) do
    %{runtime | base_env: add_trusted_workspace(runtime.base_env, path)}
  end

  def add_trusted_workspace(env, path) when is_map(env) and is_binary(path) do
    MiseEnvironment.add_trusted_workspace(env, path)
  end

  @doc "Scopes mise's writable state and cache to an individual Kogen run."
  @spec for_run(t() | map(), Path.t()) :: t() | map()
  def for_run(%__MODULE__{} = runtime, run_dir) when is_binary(run_dir) do
    %{runtime | base_env: for_run(runtime.base_env, run_dir)}
  end

  def for_run(env, run_dir) when is_map(env) and is_binary(run_dir) do
    MiseEnvironment.for_run(env, run_dir)
  end

  @spec git_environment(map()) :: %{String.t() => String.t()}
  def git_environment(env) when is_map(env) do
    Map.filter(env, fn {key, _value} ->
      key in @base_keys or String.starts_with?(key, ["GIT_", "MISE_", "KOGEN_"])
    end)
  end

  @spec temporary_directory(map()) :: Path.t()
  def temporary_directory(env) when is_map(env), do: Map.get(env, "TMPDIR", "/tmp")

  @doc "True when the environment comes from inside Kogen's own sandbox (macOS cannot nest sandboxes)."
  @spec sandboxed?(t() | %{String.t() => String.t()}) :: boolean()
  def sandboxed?(%__MODULE__{sandboxed: sandboxed}), do: sandboxed
  def sandboxed?(env) when is_map(env), do: Map.get(env, "KOGEN_SANDBOXED") == "1"

  @spec home(t()) :: Path.t() | nil
  def home(%__MODULE__{base_env: base_env}) do
    case Map.get(base_env, "HOME") do
      home when is_binary(home) and home != "" -> Path.expand(home)
      _missing -> nil
    end
  end

  @spec for_project(t(), map()) :: t()
  def for_project(%__MODULE__{} = runtime, process_env) when is_map(process_env) do
    %{runtime | git_env: git_environment(process_env)}
  end

  defp selected_environment(system_env) do
    Map.filter(system_env, fn {key, _value} ->
      key in @base_keys or String.starts_with?(key, ["GIT_", "MISE_"])
    end)
  end

  defp include_mise_binary(env, mise) do
    mise_dir = Path.dirname(mise)
    entries = env |> path_value() |> String.split(":", trim: true)
    path = Enum.join(Enum.uniq([mise_dir | entries]), ":")
    Map.merge(env, Map.new([{"PATH", path}]))
  end

  defp path_value(env) do
    Enum.find_value(env, "", fn
      {"PATH", path} -> path
      _other -> nil
    end)
  end

  defp runtime_markers(script_path, ert_dir, ert_bin) do
    case script_path do
      path when is_binary(path) ->
        Map.new([
          {"KOGEN_ERTS_DIR", ert_dir},
          {"KOGEN_ERTS_BIN", ert_bin},
          {"KOGEN_ESCRIPT_DIR", Path.dirname(path)}
        ])

      nil ->
        %{}
    end
  end

  defp runtime_markers_from(env) do
    Map.take(env, ["KOGEN_ERTS_DIR", "KOGEN_ERTS_BIN", "KOGEN_ESCRIPT_DIR", "KOGEN_BIN_DIR"])
  end

  @spec output_tail(binary()) :: String.t()
  def output_tail(output) do
    offset = max(byte_size(output) - @output_tail_bytes, 0)
    output |> binary_part(offset, byte_size(output) - offset) |> String.replace_invalid()
  end
end
