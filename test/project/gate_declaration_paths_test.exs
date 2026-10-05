defmodule Kogen.Project.GateDeclarationPathsTest do
  use ExUnit.Case, async: true

  alias Kogen.Contracts.Project
  alias Kogen.Project.GatePaths

  test "effective paths include the definition and configured gate patterns" do
    project = project("/tmp/project", gate_paths: ["Makefile", "tools/**"])

    assert GatePaths.effective(project) == [
             ".kogen/project.yaml",
             "Makefile",
             "tools/**"
           ]
  end

  test "matches exact path tokens with quoting and an optional dot prefix" do
    assert GatePaths.referenced_path(["Makefile"], "Update `./Makefile` check targets.") ==
             "Makefile"

    assert GatePaths.referenced_path(["Makefile"], "NotMakefile is unrelated.") == nil
    assert GatePaths.referenced_path(["Makefile"], "Makefile.backup is unrelated.") == nil
  end

  test "matches configured directory and glob descendants" do
    path = "tools/kogen_checks/lib/example.ex"

    assert GatePaths.referenced_path(["tools/**"], "Edit `#{path}`.") == path

    assert GatePaths.referenced_path(["tools/**/*.ex"], "Edit `tools/example.ex`.") ==
             "tools/example.ex"

    assert GatePaths.referenced_path(["tools/"], "Edit `#{path}`.") == path
    assert GatePaths.referenced_path(["tools/**"], "toolsmith/example.ex") == nil
  end

  defp project(root, options) do
    %Project{
      root: root,
      name: "project",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      gate_paths: Keyword.get(options, :gate_paths, []),
      domains: %{}
    }
  end
end
