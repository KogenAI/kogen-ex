defmodule Kogen.Contracts.MiseEnvironment do
  @moduledoc "Pure helpers for configuring mise through process environment values."

  @spec configured?(map()) :: boolean()
  def configured?(env) do
    case Map.get(env, "MISE_CONFIG_FILE") do
      path when is_binary(path) -> String.trim(path) != ""
      _missing -> false
    end
  end

  @spec trust_workspace(map(), Path.t()) :: map()
  def trust_workspace(env, path) when is_map(env) and is_binary(path),
    do: Map.put(env, "MISE_TRUSTED_CONFIG_PATHS", path)

  @spec add_trusted_workspace(map(), Path.t()) :: map()
  def add_trusted_workspace(env, path) when is_map(env) and is_binary(path) do
    paths =
      env
      |> Map.get("MISE_TRUSTED_CONFIG_PATHS", "")
      |> String.split(":", trim: true)

    Map.put(env, "MISE_TRUSTED_CONFIG_PATHS", Enum.join(Enum.uniq(paths ++ [path]), ":"))
  end

  @spec for_run(map(), Path.t()) :: map()
  def for_run(env, run_dir) when is_map(env) and is_binary(run_dir) do
    env
    |> Map.put("MISE_STATE_DIR", Path.join(run_dir, "mise-state"))
    |> Map.put("MISE_CACHE_DIR", Path.join(run_dir, "mise-cache"))
  end
end
