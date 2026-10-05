defmodule Kogen.Project.ProjectTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project
  alias Kogen.Project, as: ProjectLoader

  test "loads all declared project data and converts timeout strings", %{tmp_dir: root} do
    write_config(root, """
    name: tiny-app
    format: [mise, exec, --, mix, format]
    checks:
      - name: test
        argv: [mix, test]
        timeout_ms: 60000
    acceptance_checks:
      - name: lint-acceptance
        argv: [mix, credo, "{path}"]
        timeout_ms: 30000
    fix:
      - name: format
        argv: [mix, format, --force]
        timeout_ms: 12000
    setup:
      - name: assets
        argv: [npm, ci]
        timeout_ms: 120000
    setup_outputs: [deps, _build]
    diagnose:
      - glob: "lib/**/*.ex"
        argv: [mix, compile]
    protected_paths: [mix.exs, .kogen/project.yaml]
    domains:
      intent: [lib/kogen/intent, test/intent]
    sandbox: false
    """)

    assert {:ok, %Project{} = project} = ProjectLoader.load(root)
    assert project.root == root
    assert project.name == "tiny-app"
    assert project.checks == [%CheckSpec{name: "test", argv: ["mix", "test"], timeout_ms: 60_000}]
    assert project.format == ["mise", "exec", "--", "mix", "format"]

    assert project.acceptance_checks == [
             %CheckSpec{
               name: "lint-acceptance",
               argv: ["mix", "credo", "{path}"],
               timeout_ms: 30_000
             }
           ]

    assert project.setup == [
             %CheckSpec{name: "assets", argv: ["npm", "ci"], timeout_ms: 120_000}
           ]

    assert project.setup_outputs == ["deps", "_build"]

    assert project.fix == [
             %CheckSpec{name: "format", argv: ["mix", "format", "--force"], timeout_ms: 12_000}
           ]

    assert project.diagnose == [%{glob: "lib/**/*.ex", argv: ["mix", "compile"]}]
    assert project.protected_paths == ["mix.exs", ".kogen/project.yaml"]
    assert project.domains == %{"intent" => ["lib/kogen/intent", "test/intent"]}
    refute project.sandbox
  end

  test "omitted optional collections are empty and checks is required", %{tmp_dir: root} do
    write_config(root, "name: tiny-app\nchecks: []\n")
    assert {:ok, project} = ProjectLoader.load(root)
    assert project.acceptance_checks == []
    assert project.format == nil
    assert project.fix == []
    assert project.setup == []
    assert project.setup_outputs == []
    assert project.diagnose == []
    assert project.protected_paths == []
    assert project.domains == %{}
    assert project.sandbox

    write_config(root, "name: tiny-app\n")
    assert {:error, [%{message: message}]} = ProjectLoader.load(root)
    assert message =~ "missing required key `checks`"
  end

  test "reports a missing project file", %{tmp_dir: root} do
    assert {:error, [%{message: message}]} = ProjectLoader.load(root)
    assert message =~ ".kogen/project.yaml"
  end

  test "project config selects account, base, recipe, and role models", %{tmp_dir: root} do
    write_config(root, """
    name: tiny-app
    checks: []
    base: careful-rebuild
    account: personal
    build:
      recipe: direct
      roles:
        builder:
          model: project-model
        shaper:
          model: shape-model
          effort: low
    """)

    home = Path.join(root, "machine-home")
    machine_config = Path.join([home, ".kogen", "config.yaml"])
    File.mkdir_p!(Path.dirname(machine_config))

    File.write!(machine_config, """
    build:
      recipe: plan-shell
      roles:
        builder:
          model: machine-model
          effort: medium
        planner:
          model: machine-planner
          effort: high
    """)

    assert {:ok, project} = ProjectLoader.load(root)
    assert project.base == "careful-rebuild"
    assert project.account == "personal"
    assert {:ok, machine} = ProjectLoader.load_machine_build_settings(home)

    effective = ProjectLoader.effective_build_settings(machine, project.build)
    assert effective.recipe == "direct"
    assert effective.roles.builder == %{model: "project-model", effort: "medium"}
    assert effective.roles.planner == %{model: "machine-planner", effort: "high"}
    assert effective.roles.shaper == %{model: "shape-model", effort: "low"}

    assert effective.recipe == "direct"
    assert effective.roles.builder == %{model: "project-model", effort: "medium"}
    assert effective.roles.planner == %{model: "machine-planner", effort: "high"}
  end

  test "account defaults to the Kogen default label", %{tmp_dir: root} do
    write_config(root, "name: tiny-app\nchecks: []\n")
    assert {:ok, project} = ProjectLoader.load(root)
    assert project.account == "default"
  end

  test "sandbox accepts only a boolean project setting", %{tmp_dir: root} do
    write_config(root, "name: tiny-app\nchecks: []\nsandbox: maybe\n")

    assert {:error, [%{message: message}]} = ProjectLoader.load(root)
    assert message == "`sandbox` must be a boolean"
  end

  test "format must be a non-empty argv list", %{tmp_dir: root} do
    write_config(root, "name: tiny-app\nchecks: []\nformat: []\n")

    assert {:error, [%{message: message}]} = ProjectLoader.load(root)
    assert message == "project.format must not be empty"

    write_config(root, "name: tiny-app\nchecks: []\nformat: mix format\n")

    assert {:error, [%{message: message}]} = ProjectLoader.load(root)
    assert message == "`format` must be a list of strings"
  end

  test "rejects unknown top-level and nested keys", %{tmp_dir: root} do
    write_config(root, """
    name: tiny-app
    checks:
      - name: test
        argv: [mix, test]
        timeout_ms: 1000
        shell: true
    extra: value
    """)

    assert {:error, errors} = ProjectLoader.load(root)
    messages = Enum.map(errors, & &1.message)
    assert Enum.any?(messages, &String.contains?(&1, "project has unknown key \"extra\""))
    assert Enum.any?(messages, &String.contains?(&1, "checks[1] has unknown key \"shell\""))
  end

  test "fix entries reject tier fields and require a complete CheckSpec", %{tmp_dir: root} do
    write_config(root, """
    name: tiny-app
    checks: []
    fix:
      - name: format
        argv: [mix, format]
        timeout_ms: 1000
        tier: safe
    """)

    assert {:error, [%{message: message}]} = ProjectLoader.load(root)
    assert message =~ "fix[1] has unknown key \"tier\""

    write_config(root, """
    name: tiny-app
    checks: []
    fix:
      - name: format
        argv: [mix, format]
    """)

    assert {:error, errors} = ProjectLoader.load(root)
    assert Enum.any?(errors, &(&1.message =~ "fix[1] is missing required key `timeout_ms`"))
  end

  test "setup entries use the CheckSpec format and reject unknown keys", %{tmp_dir: root} do
    write_config(root, """
    name: tiny-app
    checks: []
    setup:
      - name: assets
        argv: [npm, ci]
        timeout_ms: 1000
        shell: true
    """)

    assert {:error, [%{message: message}]} = ProjectLoader.load(root)
    assert message =~ "setup[1] has unknown key \"shell\""

    write_config(root, """
    name: tiny-app
    checks: []
    setup:
      - name: assets
        argv: []
        timeout_ms: 1000
    """)

    assert {:error, [%{message: message}]} = ProjectLoader.load(root)
    assert message =~ "setup[1].argv must not be empty"
  end

  test "setup outputs must be safe, distinct, non-overlapping relative paths", %{tmp_dir: root} do
    write_config(root, "name: tiny-app\nchecks: []\nsetup_outputs: [../outside]\n")

    assert {:error, [%{message: message}]} = ProjectLoader.load(root)
    assert message =~ "unsafe path"

    write_config(root, "name: tiny-app\nchecks: []\nsetup_outputs: [deps, deps/cache]\n")

    assert {:error, [%{message: message}]} = ProjectLoader.load(root)
    assert message =~ "paths overlap"
  end

  test "validates argv, timeout, protected paths, diagnoses, and domain roots", %{tmp_dir: root} do
    write_config(root, """
    name: tiny-app
    checks:
      - name: test
        argv: []
        timeout_ms: zero
    protected_paths: ["", mix.exs]
    diagnose:
      - glob: ""
        argv: [mix]
    domains: intent
    """)

    assert {:error, errors} = ProjectLoader.load(root)
    messages = Enum.map(errors, & &1.message)
    assert Enum.any?(messages, &String.contains?(&1, "checks[1].argv must not be empty"))
    assert Enum.any?(messages, &String.contains?(&1, "timeout_ms must be a positive integer"))

    assert Enum.any?(
             messages,
             &String.contains?(&1, "protected_paths must contain only non-empty strings")
           )

    assert Enum.any?(
             messages,
             &String.contains?(&1, "diagnose[1].glob must be a non-empty string")
           )

    assert Enum.any?(messages, &String.contains?(&1, "`domains` must be a map"))
  end

  test "rejects non-map project roots and non-list checks", %{tmp_dir: root} do
    write_config(root, "[one, two]\n")
    assert {:error, [%{message: message}]} = ProjectLoader.load(root)
    assert message =~ "document root"

    write_config(root, "name: tiny-app\nchecks: test\n")
    assert {:error, [%{message: message}]} = ProjectLoader.load(root)
    assert message =~ "`checks` must be a list"
  end

  defp write_config(root, source) do
    config = Path.join([root, ".kogen", "project.yaml"])
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, source)
  end
end
