defmodule Kogen.Engine.RailsEnvironment do
  @moduledoc false

  alias Kogen.Contracts.Project
  alias Kogen.Contracts.Stack

  @spec apply(map(), Path.t(), Project.t()) :: map()
  def apply(env, _workdir, %Project{root: root}) do
    case Stack.detect(root) do
      :elixir ->
        env

      :rails ->
        env
        |> bundle_path()
        |> Map.put_new("BUNDLE_USER_HOME", Path.join(root, ".bundle/user"))
        |> Map.put_new("BUNDLE_APP_CONFIG", Path.join(root, ".bundle"))
        |> Map.merge(%{
          "BUNDLE_FROZEN" => "true",
          "BUNDLE_DEPLOYMENT" => "true",
          "BUNDLE_AUTO_INSTALL" => "false",
          "BUNDLE_DISABLE_VERSION_CHECK" => "true"
        })
    end
  end

  defp bundle_path(env) do
    cond do
      Map.has_key?(env, "BUNDLE_PATH") or Map.has_key?(env, "BUNDLE_APP_CONFIG") -> env
      Map.has_key?(env, "GEM_HOME") -> Map.put_new(env, "BUNDLE_PATH__SYSTEM", "true")
      true -> Map.put(env, "BUNDLE_PATH", ".bundle/gems")
    end
  end
end
