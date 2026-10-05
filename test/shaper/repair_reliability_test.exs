defmodule Kogen.Shaper.RepairReliabilityTest do
  @moduledoc false
  use Kogen.Testkit.Case

  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Proc.Sandbox
  alias Kogen.Shaper
  alias Kogen.Shaper.Request
  alias Kogen.Testkit.Git

  test "normalizes an actionable Notes paragraph to Approach without a repair", %{
    tmp_dir: tmp_dir
  } do
    project = seed_project!(Path.join(tmp_dir, "project"))

    unlabeled =
      change_intent("Change Tiny.value/0 to return :new and preserve its public function path.")

    changed_test = String.replace(acceptance_test(), ":old", ":new")

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write_many(:shape, [
          {intent_path(), unlabeled},
          {acceptance_path(), changed_test}
        ])
      ])

    config = %Config{server: server}

    try do
      assert {:ok, result} = Shaper.shape(request(project, tmp_dir, config))
      assert result.rounds == 1
      assert length(result.calls) == 1

      assert File.read!(result.intent_path) =~
               "## Notes\nApproach: Change Tiny.value/0 to return :new and preserve its public function path."

      assert File.read!(Path.join([tmp_dir, "shape-run", "logs", "shaper.log"])) =~
               "normalized intent approach label"

      instructions = hd(ScriptedProvider.requests(config)).instructions

      assert Enum.all?(
               [
                 "`size` is exactly `small`, `medium`, or `large`",
                 "Choose the smallest size that fits the finished Intent; do not default to `medium`.",
                 "Every Acceptance item has at most 25 words, regardless of size.",
                 "Use headings exactly as shown and in this order",
                 "Do not change the order of the words or omit `domain=`."
               ],
               &String.contains?(instructions, &1)
             )
    after
      GenServer.stop(server, :normal)
    end
  end

  test "reclassifies base-green test items without spending a repair", %{tmp_dir: tmp_dir} do
    project = seed_project!(Path.join(tmp_dir, "project"))

    intent_bytes = """
    ---
    title: Preserve and add Tiny value
    domains: [app]
    size: small
    ---
    Add Tiny.new_value/0 while preserving the existing Tiny.value/0 result.

    ## Acceptance
    - A1: Existing Tiny.value/0 calls continue returning :old.
    - A2: Tiny.new_value/0 returns :new for the updated result.

    ## Verify
    - A1: test domain=app
    - A2: test domain=app

    ## Notes
    Approach: Add Tiny.new_value/0 returning :new while preserving Tiny.value/0 and its existing result.
    """

    generated_intent = intent_bytes <> "\n## Request\nA model-authored substitute."

    acceptance_bytes = """
    defmodule Tiny.Acceptance.ShapeLoopTest do
      use ExUnit.Case, async: true
      @tag intent: "shape-loop/A1"
      test "the existing public function remains available" do
        assert Tiny.value() == :old
      end

      @tag intent: "shape-loop/A2"
      test "the new function returns the updated result" do
        assert function_exported?(Tiny, :new_value, 0)

        if function_exported?(Tiny, :new_value, 0) do
          assert Tiny.new_value() == :new
        end
      end
    end
    """

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write_many(:shape, [
          {intent_path(), generated_intent},
          {acceptance_path(), acceptance_bytes}
        ])
      ])

    config = %Config{server: server}

    try do
      task =
        "Add Tiny.new_value/0 while preserving Tiny.value/0.\r\n## Acceptance\r\n" <>
          String.duplicate("ensure robust ", 300) <> "TODO??\r\n"

      assert {:ok, result} = Shaper.shape(request(project, tmp_dir, config, task))
      assert result.rounds == 1
      assert length(result.calls) == 1
      assert length(ScriptedProvider.requests(config)) == 1
      assert [warning] = result.warnings
      assert warning.code == :shape_reclassified
      assert warning.item_ids == ["A1"]

      rewritten = File.read!(result.intent_path)
      assert rewritten =~ "- A1: test keep domain=app"
      assert rewritten =~ "- A2: test domain=app"
      assert {:ok, %{request: ^task}} = Kogen.Intent.parse_binary(rewritten, result.intent_path)
      assert warning.message =~ "A1 changed from test to test keep"
      assert warning.message =~ "green on the base"

      warning_path =
        Path.join([project, ".kogen", "intents", "shape-loop", "shape-warnings.json"])

      assert %{
               "warnings" => [%{"code" => "shape_reclassified", "item_ids" => ["A1"]}]
             } = :json.decode(File.read!(warning_path))
    after
      GenServer.stop(server, :normal)
    end
  end

  test "style advice stops after two repairs and saves warnings without spending structural passes",
       %{tmp_dir: tmp_dir} do
    project = seed_project!(Path.join(tmp_dir, "project"))
    notes = "Approach: Change Tiny.value/0 to return :new and preserve its public function path."

    advisory =
      notes |> change_intent() |> String.replace("keeps returning :old", "should return :new")

    write =
      ScriptedProvider.write_many(:shape, [
        {intent_path(), advisory},
        {acceptance_path(), String.replace(acceptance_test(), ":old", ":new")}
      ])

    structural = ScriptedProvider.write(:shape, intent_path(), change_intent(nil))
    {:ok, server} = ScriptedProvider.start_link([write, write, structural, structural, write])
    config = %Config{server: server}

    try do
      assert {:ok, result} = Shaper.shape(request(project, tmp_dir, config))
      assert result.rounds == 5
      requests = ScriptedProvider.requests(config)
      assert length(requests) == 5
      assert Enum.map_join(Enum.at(requests, 1).input, &inspect/1) =~ "Style advice:"
      assert Enum.map_join(Enum.at(requests, 2).input, &inspect/1) =~ "lint_hedge"

      warning_file =
        Path.join([project, ".kogen", "intents", "shape-loop", "shape-warnings.json"])

      saved = warning_file |> File.read!() |> :json.decode()

      assert Enum.any?(
               saved["warnings"],
               &(&1["code"] == "lint_hedge" and &1["item_ids"] == ["A1"])
             )

      assert File.read!(result.intent_path) =~ "should return :new"
    after
      GenServer.stop(server, :normal)
    end
  end

  test "repair exhaustion reports the actual failure and pass counts", %{tmp_dir: tmp_dir} do
    project = seed_project!(Path.join(tmp_dir, "project"))

    invalid =
      intent(
        "keeps",
        "A1 verifies the existing Tiny.value/0 result."
      )

    repeated =
      ScriptedProvider.write_many(:shape, [
        {intent_path(), invalid},
        {acceptance_path(), acceptance_test()}
      ])

    {:ok, server} = ScriptedProvider.start_link(List.duplicate(repeated, 3))
    config = %Config{server: server}

    try do
      assert {:error,
              %Kogen.Contracts.Failure{
                class: :candidate,
                reason: :intent_lint_failed,
                detail: detail
              }} = Shaper.shape(request(project, tmp_dir, config))

      assert detail =~ "Shaper repair limit reached for intent_lint_failed"
      assert detail =~ "2 repair round(s), 3 attempt(s), and 3 model call(s)"
      assert detail =~ "candidate/intent_lint_failed"

      assert File.read!(Path.join([tmp_dir, "shape-run", "logs", "shaper.log"])) =~
               "repairs=2/2 attempts=3 calls=3"
    after
      GenServer.stop(server, :normal)
    end
  end

  defp request(project, tmp_dir, %Config{} = config, task \\ nil) do
    {:ok, runtime} = Kogen.Kernel.runtime()
    {:ok, project_config} = Kogen.Project.load(project)
    {:ok, env} = Kogen.Kernel.candidate_environment(project, runtime, project_config)
    run_dir = Path.join(tmp_dir, "shape-run")

    %Request{
      workdir: project,
      slug: "shape-loop",
      task: task || "Change Tiny.value/0 to return :new while preserving its public function.",
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

  defp mix_project do
    """
    defmodule Tiny.MixProject do
      use Mix.Project
      def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.20"]
    end
    """
  end

  defp project_config do
    """
    name: tiny
    checks:
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

  defp intent_path, do: ".kogen/intents/shape-loop/intent.md"
  defp acceptance_path, do: ".kogen/acceptance/shape-loop_test.exs"
end
