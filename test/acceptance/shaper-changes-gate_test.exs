defmodule Kogen.Acceptance.ShaperChangesGateTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Project
  alias Kogen.Testkit.Git

  @moduletag :acceptance
  @slug "shaper-changes-gate"

  @tag intent: "shaper-changes-gate/A1"
  test "the prompt flags gate plans but not unrelated requests", %{tmp_dir: tmp_dir} do
    gate_project = seed_project!(Path.join(tmp_dir, "gate"))

    gate_notes =
      "Approach: Change Tiny.value/0 and update Makefile's check target while preserving its public result."

    assert {{:ok, _pass}, [gate_request]} =
             shape_with(
               gate_project,
               tmp_dir,
               "Update Tiny.value/0 and Makefile's check target.",
               intent(true, gate_notes)
             )

    assert File.read!(intent_path(gate_project)) =~ "changes_gate: true"
    assert gate_request.instructions =~ "changes_gate: true"
    assert gate_request.instructions =~ "only when"
    assert gate_request.instructions =~ "gate path"

    ordinary_project = seed_project!(Path.join(tmp_dir, "ordinary"))

    ordinary_notes =
      "Approach: Change Tiny.value/0 and preserve its public result and function path."

    assert {{:ok, _pass}, [_ordinary_request]} =
             shape_with(
               ordinary_project,
               tmp_dir,
               "Change Tiny.value/0 while preserving its public function.",
               intent(false, ordinary_notes)
             )

    refute File.read!(intent_path(ordinary_project)) =~ "changes_gate: true"
  end

  @tag intent: "shaper-changes-gate/A2"
  test "an approach naming Makefile without the flag is rejected with its path", %{
    tmp_dir: tmp_dir
  } do
    project = seed_project!(Path.join(tmp_dir, "approach"))

    source =
      intent(
        false,
        "Approach: Change Tiny.value/0 and update Makefile's check target while preserving its public result."
      )

    assert {:ok, parsed} = Kogen.Intent.parse_binary(source, ".kogen/intents/probe/intent.md")

    assert {:error, failure} = validate(project, tmp_dir, parsed, acceptance_source())
    assert failure.detail =~ "Makefile"
    assert failure.detail =~ "changes_gate"
  end

  @tag intent: "shaper-changes-gate/A3"
  test "an acceptance test writing a gate file is rejected with its path", %{tmp_dir: tmp_dir} do
    project = seed_project!(Path.join(tmp_dir, "acceptance"))

    source =
      intent(
        false,
        "Approach: Change Tiny.value/0 and preserve its public result and function path."
      )

    assert {:ok, parsed} = Kogen.Intent.parse_binary(source, ".kogen/intents/probe/intent.md")

    assert {:error, failure} = validate(project, tmp_dir, parsed, acceptance_source(:writes_gate))
    assert failure.detail =~ ".credo.exs"
    assert failure.detail =~ "changes_gate"
  end

  defp shape_with(project, tmp_dir, task, generated_intent) do
    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write_many(:shape, [
          {intent_path(project), generated_intent},
          {".kogen/acceptance/#{@slug}_test.exs", acceptance_source()}
        ])
      ])

    config = %Config{server: server}

    try do
      result = Harness.shape(options(project, tmp_dir, config), @slug, task, [], nil, 0)
      {result, ScriptedProvider.requests(config)}
    after
      GenServer.stop(server, :normal)
    end
  end

  defp options(project, tmp_dir, config) do
    {:ok, project_config} = Project.load(project)

    %Opts{
      workdir: project,
      run_dir: Path.join(tmp_dir, "harness-run-#{Path.basename(project)}"),
      project: project_config,
      provider_mod: ScriptedProvider,
      provider_config: config,
      proc_mod: Kogen.Proc,
      changed?: fn -> {:ok, true} end,
      env: %{},
      models: %{builder: {"scripted-model", "low"}, strong: {"scripted-model", "low"}},
      limits: %{max_turns: 12, wall_ms: 60_000}
    }
  end

  defp validate(project, tmp_dir, parsed_intent, test_bytes) do
    {:ok, project_config} = Project.load(project)

    Kogen.Checks.validate_shape(%Kogen.Checks.ShapeValidation{
      workdir: project,
      project: project_config,
      intent: parsed_intent,
      acceptance_bytes: test_bytes,
      run_dir: Path.join(tmp_dir, "checks-run"),
      env: %{"MIX_ENV" => "test"},
      git_env: Git.env()
    })
  end

  defp intent_path(project), do: Path.join(project, ".kogen/intents/#{@slug}/intent.md")

  defp intent(changes_gate?, notes) do
    flag = if changes_gate?, do: "changes_gate: true\n", else: ""

    """
    ---
    title: Change Tiny value
    domains: [app]
    size: small
    #{flag}---
    Change Tiny.value/0 to return :new while preserving its public function.

    ## Acceptance
    - A1: Tiny.value/0 returns :new on the unchanged checkout.

    ## Verify
    - A1: test domain=app

    ## Notes
    #{notes}
    """
  end

  defp acceptance_source(mode \\ :normal) do
    assertion =
      if mode == :writes_gate,
        do: ~s{assert File.write!(".credo.exs", "changed\\n") == :ok},
        else: "assert Tiny.value() == :new"

    """
    defmodule Tiny.Acceptance.ShaperChangesGateTest do
      use ExUnit.Case, async: true
      @tag intent: "shaper-changes-gate/A1"
      test "the requested value is returned" do
        #{assertion}
      end
    end
    """
  end

  defp seed_project!(project) do
    File.mkdir_p!(Path.join(project, ".kogen"))
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(Path.join(project, "test"))

    File.write!(
      Path.join(project, "mix.exs"),
      ~s(defmodule Tiny.MixProject do\n  use Mix.Project\n  def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.20"]\nend\n)
    )

    File.write!(
      Path.join(project, "lib/tiny.ex"),
      "defmodule Tiny do\n  def value, do: :old\nend\n"
    )

    File.write!(Path.join(project, "test/test_helper.exs"), "ExUnit.start()\n")
    File.write!(Path.join(project, "Makefile"), "check:\n\t@true\n")
    File.write!(Path.join(project, ".credo.exs"), "[]\n")
    File.write!(Path.join(project, ".kogen/project.yaml"), project_config())
    Git.git!(project, ["init", "--quiet", "--template="])
    Git.git!(project, ["add", "--all"])
    Git.git!(project, ["commit", "--quiet", "-m", "Seed gate shaping fixture"])
    project
  end

  defp project_config do
    """
    name: tiny
    checks:
      - name: tests
        argv: [true]
        timeout_ms: 10000
    acceptance_checks:
      - name: acceptance
        argv: [true]
        timeout_ms: 10000
    gate_paths: [Makefile, .credo.exs]
    domains:
      app: [lib, test]
    """
  end
end
