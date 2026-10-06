defmodule Kogen.E2e.IncrementalBuilderTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @moduletag timeout: 300_000

  test "short shell turns preserve multiple files and resume a red completion gate", %{
    tmp_dir: tmp
  } do
    seed =
      Kogen.E2e.Ladder.seed!(Path.join(tmp, "seed"), intent: intent(), acceptance: acceptance())

    broken = "defmodule TinyApp do\n  def value, do: :pending\nend\n"
    ready = "defmodule TinyApp do\n  def value, do: :ready\nend\n"

    script = [
      ScriptedProvider.answer(:develop, "Inspecting the next decision."),
      shell("sed -n '1,30p' lib/tiny_app.ex"),
      shell("cat > lib/tiny_app.ex <<'EOF'\n#{broken}EOF"),
      shell("sed -n '1,30p' lib/tiny_app.ex"),
      shell("printf 'incremental fixture\\n' > lib/build-note.txt"),
      shell("test -s lib/build-note.txt"),
      ScriptedProvider.finish(),
      shell("cat > lib/tiny_app.ex <<'EOF'\n#{ready}EOF"),
      shell("mix test test/acceptance/build-engine_test.exs"),
      ScriptedProvider.finish()
    ]

    result =
      Build.run!(tmp, script, %Options{
        seed_project: seed,
        recipe: "direct-shell",
        builder_model: "gpt-6-luna",
        builder_effort: "max"
      })

    assert result.build.status == :landed
    assert {:ok, report} = Build.report(result)
    assert :json.decode(report)["recipe"] == "direct-shell"

    assert Git.git!(result.fixture.origin, [
             "show",
             "#{result.build.landed_sha}:lib/build-note.txt"
           ]) ==
             "incremental fixture\n"

    records =
      result.build.run_dir
      |> Path.join("requests.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)

    attempts = Enum.filter(records, &Map.has_key?(&1, "started_at"))

    assert Enum.map(attempts, & &1["response_kind"]) ==
             [
               "progress",
               "tools",
               "tools",
               "tools",
               "tools",
               "tools",
               "finish",
               "tools",
               "tools",
               "finish"
             ]

    assert Enum.all?(attempts, &(&1["model"] == "gpt-6-luna" and &1["effort"] == "max"))

    assert Enum.map(Enum.filter(records, &(&1["event"] == "builder_gate")), & &1["gate_status"]) ==
             ["fail", "pass"]

    assert Enum.all?(
             Enum.flat_map(result.provider_requests, & &1.tools),
             &(&1["parameters"]["additionalProperties"] == false)
           )

    shell_results =
      result.build.run_dir
      |> Path.join("transcript.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)
      |> Enum.filter(&(&1["event"] == "tool_result" and &1["payload"]["call"]["name"] == "shell"))

    assert length(shell_results) == 7
    assert Enum.all?(shell_results, &(&1["payload"]["result"]["is_error"] == false))
  end

  defp shell(cmd), do: ScriptedProvider.call(:develop, "shell", %{"cmd" => cmd})

  defp intent do
    """
    ---
    title: Expose a ready value and a build note
    domains: [kernel]
    size: small
    ---
    Change lib/tiny_app.ex and lib/build-note.txt.
    ## Acceptance
    - A1: TinyApp.value/0 returns :ready.
    - A2: lib/build-note.txt contains exactly "incremental fixture" followed by a newline.
    ## Verify
    - A1: test
    - A2: test
    """
  end

  defp acceptance do
    """
    defmodule TinyApp.AcceptanceTest do
      use ExUnit.Case, async: true
      @tag intent: "build-engine/A1"
      test "returns the ready value", do: assert(TinyApp.value() == :ready)
      @tag intent: "build-engine/A2"
      test "keeps the exact build note", do: assert(File.read!("lib/build-note.txt") == "incremental fixture\\n")
    end
    """
  end
end
