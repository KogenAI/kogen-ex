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
        |> then(&Map.merge(Map.new([{"BUNDLE_PATH", "vendor/bundle"}]), &1))
        |> Map.put("BUNDLE_USER_HOME", Path.join(root, ".kogen/bundle"))
        |> Map.put("BUNDLE_APP_CONFIG", Path.join(root, ".bundle"))
    end
  end
end
