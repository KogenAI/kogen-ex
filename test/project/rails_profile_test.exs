defmodule Kogen.Project.RailsProfileTest do
  use Kogen.Testkit.Case

  alias Kogen.Project

  test "Rails projects have local Bundler setup and Rails checks without a Mix configuration", %{
    tmp_dir: root
  } do
    rails_project!(root)
    assert {:ok, project} = Project.load(root)
    assert Enum.map(project.checks, & &1.argv) == [["bundle", "exec", "rails", "test"]]
    assert Enum.map(project.setup, & &1.name) == ["bundle"]
    assert Enum.map(project.acceptance_checks, & &1.argv) == [["ruby", "-c", "{path}"]]
    assert project.format == nil

    File.rm!(Path.join(root, "config/application.rb"))
    assert {:error, errors} = Project.load(root)
    assert Enum.any?(errors, &String.contains?(&1.message, "missing required key `checks`"))
  end

  test "Rails enables declared linters and their formatter, preserving explicit commands", %{
    tmp_dir: root
  } do
    rails_project!(root)
    File.write!(Path.join(root, "Gemfile"), "gem 'standard'\ngem 'rubocop-rails'\n")

    assert {:ok, project} = Project.load(root)
    assert Enum.map(project.checks, & &1.name) == ["tests", "standard", "rubocop"]
    assert project.format == ["bundle", "exec", "standardrb", "-a"]
    assert Enum.map(project.fix, & &1.argv) == [project.format]

    File.write!(Path.join(root, "Gemfile"), "gem 'rubocop'\n")
    assert {:ok, project} = Project.load(root)
    assert project.format == ["bundle", "exec", "rubocop", "-a"]

    File.write!(Path.join(root, ".kogen/project.yaml"), """
    name: rails
    checks:
      - name: own-tests
        argv: [bin/rails, test, test/models]
        timeout_ms: 10000
    setup: []
    format: [bin/rubocop, -a]
    """)

    assert {:ok, project} = Project.load(root)
    assert Enum.map(project.checks, & &1.argv) == [["bin/rails", "test", "test/models"]]
    assert project.setup == []
    assert project.format == ["bin/rubocop", "-a"]
  end

  defp rails_project!(root) do
    File.mkdir_p!(Path.join(root, ".kogen"))
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, ".kogen/project.yaml"), "name: rails\n")
    File.write!(Path.join(root, "Gemfile"), "gem 'rails'\n")
    File.write!(Path.join(root, "config/application.rb"), "class Application; end\n")
  end
end
