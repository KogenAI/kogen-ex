defmodule Kogen.Shaper.IntentCapacityTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Shaper
  alias Kogen.Shaper.Request
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.IntentFixture

  test "shaping keeps twelve outcomes, shared constraints and five domains in one Intent", %{
    tmp_dir: root
  } do
    project = seed!(Path.join(root, "project"))
    domains = ~w(one two three four five)

    items =
      Enum.map(1..12, &{"A#{&1}", "Part #{&1} returns the new tuple under the shared format."})

    source =
      IntentFixture.source(%{
        size: "large",
        domains: domains,
        items: items,
        verify: Enum.map(items, fn {id, _text} -> {id, "test domain=one"} end),
        notes:
          "Approach: Extend Tiny.part/1 for all twelve outcomes and preserve the shared tuple format."
      })

    task = "Deliver twelve parts, each returning {:new, its index}. Keep the shared tuple format."

    {:ok, server} =
      ScriptedProvider.start_link([
        ScriptedProvider.write_many(:shape, [
          {".kogen/intents/large-change/intent.md", source},
          {".kogen/acceptance/large-change_test.exs", acceptance()}
        ])
      ])

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    {:ok, runtime} = Kogen.Kernel.runtime()
    {:ok, config} = Kogen.Project.load(project)
    {:ok, env} = Kogen.Kernel.candidate_environment(project, runtime, config)

    assert {:ok, result} =
             Shaper.shape(%Request{
               workdir: project,
               slug: "large-change",
               task: task,
               model: "scripted-model",
               effort: "low",
               provider_mod: ScriptedProvider,
               provider_config: %Config{server: server},
               env: Map.put(env, "MIX_ENV", "test"),
               git_env: Git.env(),
               run_dir: Path.join(root, "shape-run")
             })

    assert result.rounds == 1
    assert {:ok, shaped} = Kogen.Intent.parse(result.intent_path)
    assert shaped.domains == domains
    assert Enum.map(shaped.acceptance, &{&1.id, &1.text}) == items
    assert shaped.request == task
    assert shaped.notes =~ "preserve the shared tuple format"
    assert result.warnings == []
    for n <- 1..12, do: assert(File.read!(result.acceptance_path) =~ "large-change/A#{n}\"")
  end

  defp seed!(project) do
    project = Git.create!(project)

    files = %{
      "mix.exs" =>
        "defmodule Tiny.MixProject do\n  use Mix.Project\n  def project, do: [app: :tiny, version: \"0.1.0\"]\nend\n",
      "lib/tiny.ex" => "defmodule Tiny do\n  def part(n), do: {:old, n}\nend\n",
      "test/test_helper.exs" => "ExUnit.start()\n",
      ".gitignore" => "_build/\ndeps/\n",
      ".kogen/project.yaml" =>
        "name: tiny\nchecks:\n  - name: tests\n    argv: [mix, test]\n    timeout_ms: 60000\ndomains:\n" <>
          Enum.map_join(~w(one two three four five), &"  #{&1}: [lib]\n")
    }

    for {path, bytes} <- files do
      path = Path.join(project, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    Git.git!(project, ["add", "--all"])
    Git.git!(project, ["commit", "--quiet", "-m", "Seed complete change"])
    project
  end

  defp acceptance do
    tests =
      Enum.map_join(1..12, "\n", fn n ->
        "  @tag intent: \"large-change/A#{n}\"\n  test \"part #{n}\" do\n    assert Tiny.part(#{n}) == {:new, #{n}}\n  end\n"
      end)

    "defmodule Tiny.CapacityTest do\n  use ExUnit.Case, async: true\n#{tests}end\n"
  end
end
