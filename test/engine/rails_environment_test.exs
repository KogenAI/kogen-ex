defmodule Kogen.Engine.RailsEnvironmentTest do
  use Kogen.Testkit.Case

  alias Kogen.Engine
  alias Kogen.Engine.Runtime
  alias Kogen.Project

  for key <- ["BUNDLE_PATH", "GEM_HOME", "BUNDLE_APP_CONFIG"] do
    test "Rails honours inherited #{key} without selecting a different gem cache", %{
      tmp_dir: root
    } do
      key = unquote(key)
      File.mkdir_p!(Path.join(root, "config"))
      File.mkdir_p!(Path.join(root, ".kogen"))
      File.write!(Path.join(root, "Gemfile"), "gem 'rails'\n")
      File.write!(Path.join(root, "config/application.rb"), "class Application; end\n")
      File.write!(Path.join(root, ".kogen/project.yaml"), "name: rails\n")
      mise = Path.join(root, "mise")
      File.write!(mise, "#!/bin/sh\nprintf '{}\\n'\n")
      File.chmod!(mise, 0o755)
      cache = Path.join(root, "seeded-cache")
      runtime = Runtime.new(%{key => cache}, mise, nil, "/erts", "/erts/bin")
      assert {:ok, profile} = Project.load(root)
      assert {:ok, env} = Engine.candidate_environment(root, runtime, profile)
      assert env[key] == cache
      if key != "BUNDLE_PATH", do: refute(Map.has_key?(env, "BUNDLE_PATH"))
    end
  end
end
