defmodule Kogen.Kernel.RuntimeDiscovery do
  @moduledoc false

  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.ProviderError
  alias Kogen.Engine.Runtime
  alias Kogen.Proc
  alias Kogen.Provider.ChatGPT

  @proxy_environment_keys ~w(https_proxy HTTPS_PROXY all_proxy ALL_PROXY http_proxy HTTP_PROXY no_proxy NO_PROXY)

  @spec runtime() ::
          {:ok, Runtime.t()}
          | {:error,
             :mise_missing | :too_many_script_symlinks | {:script_path_unavailable, term()}}
  def runtime do
    system_env = System.get_env()
    mise = System.find_executable("mise")
    ert = runtime_path(:erts)
    bindir = runtime_path(:bindir)

    case mise do
      nil -> {:error, :mise_missing}
      path -> runtime_with_script(system_env, path, ert, bindir)
    end
  end

  @spec home() :: {:ok, Path.t()} | {:error, :home_unavailable}
  def home do
    case System.get_env("HOME") do
      home when is_binary(home) and home != "" ->
        {:ok, Path.expand(home)}

      _missing ->
        case System.user_home() do
          home when is_binary(home) and home != "" -> {:ok, Path.expand(home)}
          _missing -> {:error, :home_unavailable}
        end
    end
  end

  @spec resolve_script_path(Path.t() | nil) :: {:ok, Path.t() | nil} | {:error, term()}
  def resolve_script_path(nil), do: {:ok, nil}

  def resolve_script_path(path) when is_binary(path) do
    resolve_script_link(Path.expand(path), 0)
  end

  @spec provider_config(keyword()) ::
          {:ok, ChatGPT.Config.t(), :kogen_owned | :codex_borrowed | :custom, String.t()}
          | {
              :error,
              ProviderError.t()
            }
  def provider_config(opts \\ []) do
    with {:ok, home} <- home() do
      borrow = Keyword.get(opts, :borrow)
      label = Keyword.get(opts, :label, "default")
      explicit = System.get_env("KOGEN_AUTH_PATH")

      cond do
        borrow == :codex ->
          [home, ".codex", "auth.json"]
          |> Path.join()
          |> ChatGPT.borrowed_codex_config()
          |> with_source(:codex_borrowed, "codex")

        is_binary(explicit) and explicit != "" ->
          explicit |> Path.expand() |> ChatGPT.config() |> with_source(:custom, "custom")

        true ->
          home
          |> Path.join(".kogen")
          |> ChatGPT.owned_config(credential_backend(), label)
          |> with_source(:kogen_owned, label)
      end
    end
  end

  @spec provider_root() :: {:ok, Path.t()} | {:error, :home_unavailable}
  def provider_root do
    with {:ok, home} <- home(), do: {:ok, Path.join(home, ".kogen")}
  end

  @spec credential_backend() :: :file | :keychain
  def credential_backend do
    case :os.type() do
      {:unix, :darwin} -> :keychain
      _other -> :file
    end
  end

  @spec proxy_environment() :: %{String.t() => String.t()}
  def proxy_environment, do: Map.take(System.get_env(), @proxy_environment_keys)

  @spec open_browser(String.t()) :: :ok | {:error, term()}
  def open_browser(url) when is_binary(url) do
    executable =
      case :os.type() do
        {:unix, :darwin} -> "open"
        {:unix, _system} -> "xdg-open"
        _other -> nil
      end

    case executable && System.find_executable(executable) do
      nil ->
        {:error, :browser_unavailable}

      path ->
        case Proc.run([path, url],
               cd: System.tmp_dir!(),
               env: browser_environment(),
               timeout_ms: 10_000
             ) do
          {:ok, %ProcResult{exit_status: 0, timed_out: false}} -> :ok
          _result -> {:error, :browser_open_failed}
        end
    end
  rescue
    ArgumentError -> {:error, :browser_open_failed}
    ErlangError -> {:error, :browser_open_failed}
  end

  defp runtime_with_script(system_env, mise, ert, bindir) do
    with {:ok, script} <- resolve_script_path(escript_path()) do
      {:ok, Runtime.new(system_env, mise, script, ert, bindir)}
    end
  end

  defp with_source({:ok, config}, source, label) do
    {:ok, %{config | proxy_env: proxy_environment()}, source, label}
  end

  defp with_source({:error, %ProviderError{}} = error, _source, _label), do: error

  defp browser_environment do
    Map.take(System.get_env(), [
      "PATH",
      "HOME",
      "LANG",
      "DISPLAY",
      "WAYLAND_DISPLAY",
      "XAUTHORITY",
      "XDG_RUNTIME_DIR",
      "DBUS_SESSION_BUS_ADDRESS",
      "XDG_CURRENT_DESKTOP"
    ])
  end

  defp escript_path do
    case :escript.script_name() do
      [] ->
        nil

      name ->
        path = List.to_string(name)
        if File.regular?(path), do: path
    end
  end

  defp resolve_script_link(_path, depth) when depth >= 40, do: {:error, :too_many_script_symlinks}

  defp resolve_script_link(path, depth) do
    case File.read_link(path) do
      {:ok, target} -> resolve_script_link(Path.expand(target, Path.dirname(path)), depth + 1)
      {:error, :einval} -> {:ok, path}
      {:error, reason} -> {:error, {:script_path_unavailable, reason}}
    end
  end

  defp runtime_path(:erts), do: :erts |> :code.lib_dir() |> List.to_string()

  defp runtime_path(:bindir) do
    :code.root_dir() |> List.to_string() |> Path.join("bin")
  end
end
