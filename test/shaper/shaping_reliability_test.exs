defmodule Kogen.Shaper.ShapingReliabilityTests do
  @moduledoc false
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProviderError
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Kernel.CLI
  alias Kogen.Kernel.CLI.ShapeJson
  alias Kogen.Proc.Sandbox
  alias Kogen.Resilience.Policy
  alias Kogen.Shaper
  alias Kogen.Shaper.Request
  alias Kogen.Testkit.Git

  test "reclassifies a keep that fails on base and shows the warning at approval", %{
    tmp_dir: tmp_dir
  } do
    project = seed_project!(Path.join(tmp_dir, "project"))

    intent_bytes =
      "keeps"
      |> intent(
        "Approach: Change Tiny.value/0 and update its return path so the requested new value is observable."
      )
      |> String.replace("returning :old", "returning :new")

    acceptance_bytes = String.replace(acceptance_test(), ":old", ":new")

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write_many(:shape, [
          {intent_path(), intent_bytes},
          {acceptance_path(), acceptance_bytes}
        ])
      ])

    config = %Config{server: server}

    try do
      assert {:ok, result} = Shaper.shape(request(project, tmp_dir, config))
      assert result.rounds == 1
      assert length(result.calls) == 1
      assert [warning] = result.warnings
      assert warning.code == :shape_reclassified
      assert warning.item_ids == ["A1"]

      assert %{"warnings" => [%{"code" => "shape_reclassified", "item_ids" => ["A1"]}]} =
               result |> ShapeJson.encode() |> :json.decode()

      assert File.read!(result.intent_path) =~ "- A1: test domain=app"
      assert File.read!(result.intent_path) =~ "Tiny.value/0 keeps returning :new"
      refute File.read!(result.intent_path) =~ "- A1: test keep"

      warning_path =
        Path.join([project, ".kogen", "intents", "shape-loop", "shape-warnings.json"])

      assert %{
               "intent_sha256" => intent_hash,
               "warnings" => [%{"code" => "shape_reclassified", "item_ids" => ["A1"]}]
             } =
               :json.decode(File.read!(warning_path))

      assert Kogen.Intent.hash(File.read!(result.intent_path)) == intent_hash
      assert length(ScriptedProvider.requests(config)) == 1

      Git.git!(project, ["branch", "-M", "main"])

      assert {5, card} =
               CLI.execute([
                 "intent",
                 "approve",
                 "shape-loop",
                 "--project",
                 project,
                 "--origin",
                 project,
                 "--base",
                 "main",
                 "--by",
                 "T22"
               ])

      assert card =~ "shape_reclassified"
      assert card =~ "A1 changed from test keep to test"

      assert card =~
               "Approve with:\n  kogen intent approve shape-loop #{binary_part(intent_hash, 0, 8)}\n"
    after
      GenServer.stop(server, :normal)
    end
  end

  test "repair feedback names both required paths and their current file state", %{
    tmp_dir: tmp_dir
  } do
    project = seed_project!(Path.join(tmp_dir, "project"))

    invalid_intent = intent("usually keeps", "A1 verifies Tiny.value/0 returns :old.")

    valid_intent =
      change_intent(
        "Approach: Change Tiny.value/0 to return :new and preserve its public function path."
      )

    changed_test = String.replace(acceptance_test(), ":old", ":new")

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write(:shape, intent_path(), invalid_intent),
        ScriptedProvider.write(:shape, intent_path(), valid_intent),
        ScriptedProvider.write(:shape, acceptance_path(), changed_test)
      ])

    config = %Config{server: server}

    try do
      assert {:ok, result} = Shaper.shape(request(project, tmp_dir, config))
      assert result.rounds == 3

      [_, intent_repair, acceptance_repair] = ScriptedProvider.requests(config)
      intent_feedback = Enum.map_join(intent_repair.input, &inspect/1)
      acceptance_feedback = Enum.map_join(acceptance_repair.input, &inspect/1)

      assert intent_feedback =~ "#{intent_path()}`: present on disk"
      assert intent_feedback =~ "#{acceptance_path()}`: missing or unreadable"
      assert intent_feedback =~ "Every missing path must be written now"

      assert acceptance_feedback =~ "#{intent_path()}`: present on disk"
      assert acceptance_feedback =~ "#{acceptance_path()}`: missing or unreadable"
      assert acceptance_feedback =~ "Write it during this repair pass at this exact path"
      assert File.read!(result.acceptance_path) == changed_test
    after
      GenServer.stop(server, :normal)
    end
  end

  test "retries an all-keep intent that does not prove a change", %{tmp_dir: tmp_dir} do
    project = seed_project!(Path.join(tmp_dir, "project"))

    keep_intent =
      intent(
        "keeps",
        "Approach: Keep Tiny.value/0 unchanged and preserve its public result by avoiding unrelated changes."
      )

    change_intent = String.replace(keep_intent, "test keep domain=app", "test domain=app")
    changed_test = String.replace(acceptance_test(), ":old", ":new")

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write_many(:shape, [
          {intent_path(), keep_intent},
          {acceptance_path(), acceptance_test()}
        ]),
        ScriptedProvider.write_many(:shape, [
          {intent_path(), change_intent},
          {acceptance_path(), changed_test}
        ])
      ])

    config = %Config{server: server}

    try do
      assert {:ok, result} = Shaper.shape(request(project, tmp_dir, config))
      assert result.rounds == 2
      repair = Enum.map_join(Enum.at(ScriptedProvider.requests(config), 1).input, &inspect/1)
      assert repair =~ "all_items_keep"
      assert repair =~ "No non-keep acceptance item is red on the unchanged base"
      assert repair =~ "base=passed"
      assert repair =~ "Acceptance test: test the existing public value remains available"
      assert length(result.calls) == 2
    after
      GenServer.stop(server, :normal)
    end
  end

  test "uses three structural validation passes within the existing turn and wall limits", %{
    tmp_dir: tmp_dir
  } do
    project = seed_project!(Path.join(tmp_dir, "project"))

    invalid_intent =
      intent(
        "keeps",
        "A1 verifies the existing Tiny.value/0 result."
      )

    valid_intent =
      change_intent(
        "Approach: Change Tiny.value/0 to return :new and preserve its public function path."
      )

    steps =
      List.duplicate(
        ScriptedProvider.write_many(:shape, [
          {intent_path(), invalid_intent},
          {acceptance_path(), acceptance_test()}
        ]),
        2
      ) ++
        [
          ScriptedProvider.write_many(:shape, [
            {intent_path(), valid_intent},
            {acceptance_path(), String.replace(acceptance_test(), ":old", ":new")}
          ])
        ]

    {:ok, server} = ScriptedProvider.start_link(steps)
    config = %Config{server: server}

    try do
      shape_request = request(project, tmp_dir, config)
      assert shape_request.limits == %{max_turns: 60, wall_ms: :infinity}
      assert {:ok, result} = Shaper.shape(shape_request)
      assert result.rounds == 3
      assert length(result.calls) == 3
      assert length(ScriptedProvider.requests(config)) == 3

      run_log = File.read!(Path.join([tmp_dir, "shape-run", "logs", "shaper.log"]))
      assert run_log =~ "attempt=3 started turns_used=2/60"
      assert run_log =~ "attempt=3 validation_passed"
    after
      GenServer.stop(server, :normal)
    end
  end

  test "shaping keeps its selected model through repeated overloads when fallback is disabled", %{
    tmp_dir: tmp_dir
  } do
    project = seed_project!(Path.join(tmp_dir, "project"))
    steps = List.duplicate(ScriptedProvider.fail(:shape, :overload), 5)
    {:ok, server} = ScriptedProvider.start_link(steps ++ [ScriptedProvider.fail(:shape, :login)])
    config = %Config{server: server}

    try do
      shape_request = %{
        request(project, tmp_dir, config)
        | resilience: %Policy{model_fallback: false, backoff_base_ms: 1, backoff_max_ms: 2},
          limits: %{max_turns: 60, wall_ms: 5_000}
      }

      assert {:error, %ProviderError{class: :login}} = Shaper.shape(shape_request)
      requests = ScriptedProvider.requests(config)
      assert length(requests) == 6

      assert Enum.all?(
               requests,
               &(&1.model == shape_request.model and &1.effort == shape_request.effort)
             )
    after
      GenServer.stop(server, :normal)
    end
  end

  defp request(project, tmp_dir, %Config{} = config) do
    {:ok, runtime} = Kogen.Kernel.runtime()
    {:ok, project_config} = Kogen.Project.load(project)
    {:ok, env} = Kogen.Kernel.candidate_environment(project, runtime, project_config)
    run_dir = Path.join(tmp_dir, "shape-run")

    %Request{
      workdir: project,
      slug: "shape-loop",
      task: "Change Tiny.value/0 to return :new while preserving its public function.",
      model: "scripted-model",
      effort: "low",
      provider_mod: ScriptedProvider,
      provider_config: config,
      env: Map.merge(env, %{"MIX_ENV" => "test", "ERL_FLAGS" => "+S 1:1 +A 1"}),
      git_env: Git.env(),
      run_dir: run_dir,
      sandbox: %Sandbox{
        enabled: project_config.sandbox and not Map.get(runtime, :sandboxed, false),
        home: runtime.base_env["HOME"],
        project_root: project,
        origin: project,
        workspace: project,
        run_dir: run_dir,
        tmp_dir: Map.get(env, "TMPDIR", "/tmp"),
        workspace_is_project: true
      }
    }
  end

  defp seed_project!(project) do
    File.mkdir_p!(Path.join(project, ".kogen"))
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(Path.join(project, "test"))
    File.write!(Path.join(project, "mix.exs"), mix_project())

    File.write!(
      Path.join(project, "lib/tiny.ex"),
      "defmodule Tiny do\n  def value, do: :old\nend\n"
    )

    File.write!(Path.join(project, "test/test_helper.exs"), "ExUnit.start()\n")
    File.write!(Path.join(project, ".gitignore"), "_build/\ndeps/\ncover/\n")
    File.write!(Path.join(project, ".kogen/project.yaml"), project_config())
    Git.git!(project, ["init", "--quiet", "--template="])
    Git.git!(project, ["add", "--all"])
    Git.git!(project, ["commit", "--quiet", "-m", "Seed shaper fixture"])
    project
  end

  defp mix_project do
    """
    defmodule Tiny.MixProject do
      use Mix.Project

      def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.20"]
    end
    """
  end

  defp project_config(format_argv \\ nil) do
    format_config =
      if format_argv do
        "format: [" <> Enum.map_join(format_argv, ", ", &inspect/1) <> "]\n"
      else
        ""
      end

    """
    name: tiny
    #{format_config}checks:
      - name: tests
        argv: [mix, test]
        timeout_ms: 120000
    acceptance_checks:
      - name: format
        argv: [mix, format, --check-formatted, "{path}"]
        timeout_ms: 120000
    domains:
      app: [lib, test]
    """
  end

  defp intent(acceptance_text, notes) do
    notes_section = if notes, do: "\n\n## Notes\n#{notes}\n", else: ""

    String.trim_leading("""
    ---
    title: Keep Tiny value
    domains: [app]
    size: small
    ---
    Keep the existing public Tiny.value/0 result.

    ## Acceptance
    - A1: Tiny.value/0 #{acceptance_text} returning :old on the unchanged checkout.

    ## Verify
    - A1: test keep domain=app
    #{notes_section}
    """)
  end

  defp change_intent(notes) do
    "keeps"
    |> intent(notes)
    |> String.replace(
      "Tiny.value() keeps returning :old on the unchanged checkout.",
      "Tiny.value() returns :new on the unchanged checkout."
    )
    |> String.replace("test keep domain=app", "test domain=app")
  end

  defp acceptance_test do
    """
    defmodule Tiny.Acceptance.ShapeLoopTest do
      use ExUnit.Case, async: true
      @tag intent: "shape-loop/A1"
      test "the existing public value remains available" do
        assert(Tiny.value() == :old)
      end
    end
    """
  end

  defp intent_path, do: ".kogen/intents/shape-loop/intent.md"
  defp acceptance_path, do: ".kogen/acceptance/shape-loop_test.exs"
end
