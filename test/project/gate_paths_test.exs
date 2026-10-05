defmodule Kogen.Project.GatePathsTest do
  use ExUnit.Case, async: true

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project

  @tracked ["Makefile", "mix.exs", "ci/check.sh", "ci/lint.sh", "lib/app.ex"]

  test "gate files are protected beside the declared protected paths" do
    patterns = Kogen.Project.protected_patterns(project(), false, @tracked)

    assert patterns == [
             "mix.exs",
             ".kogen/project.yaml",
             "Makefile",
             ".credo.exs",
             "ci/check.sh",
             "ci/lint.sh"
           ]

    refute "lib/app.ex" in patterns
  end

  test "make commands protect the Makefile they run" do
    project = %{
      project()
      | checks: [%CheckSpec{name: "full", argv: ["make", "check"], timeout_ms: 1}],
        gate_paths: []
    }

    assert "Makefile" in Kogen.Project.protected_patterns(project, false, @tracked)
  end

  test "an Intent that changes the gate keeps only the declared protected paths" do
    assert Kogen.Project.protected_patterns(project(), true, @tracked) == ["mix.exs"]
  end

  test "command arguments that are not tracked files are ignored" do
    patterns = Kogen.Project.protected_patterns(project(), false, ["mix.exs"])

    refute "ci/check.sh" in patterns
    refute "make" in patterns
  end

  test "literal patterns missing from the base tree must stay absent" do
    patterns = [".dialyzer_ignore.exs", "Makefile", "tools/**", "ci/", "lib"]

    assert Kogen.Project.absent_candidates(patterns, @tracked) == [".dialyzer_ignore.exs"]
  end

  defp project do
    %Project{
      root: "/tmp/app",
      name: "app",
      checks: [
        %CheckSpec{name: "full", argv: ["./ci/check.sh", "lib/app.ex"], timeout_ms: 1_000}
      ],
      setup: [],
      fix: [
        %CheckSpec{name: "fmt", argv: ["sh", "-e", "ci/lint.sh", "lib/app.ex"], timeout_ms: 1_000}
      ],
      diagnose: [%{glob: "lib/**/*.ex", argv: ["mix", "compile"]}],
      protected_paths: ["mix.exs"],
      gate_paths: ["Makefile", ".credo.exs"],
      domains: %{}
    }
  end
end
