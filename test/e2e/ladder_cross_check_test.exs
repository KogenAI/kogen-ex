defmodule Kogen.E2e.LadderCrossCheckTest do
  use Kogen.Testkit.Case

  import Kogen.E2e.Ladder, only: [done: 0, events: 2, shell: 1, source_at: 2]

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.Ladder
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Temp

  @moduletag :e2e
  @moduletag timeout: 300_000

  @hard_plan "Difficulty: hard\n## Acceptance criteria\n1. TinyApp.value/0 returns :ready."

  setup_all do
    root = Temp.create!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, seed: Ladder.seed!(root)}
  end

  test "two green parallel rungs land the one that passes the other's tests", context do
    result = run!(context, "cross", %{})

    assert %Result{build: %{status: :landed, landed_sha: sha}} = result
    assert source_at(result, sha) =~ "# revision: builder"

    assert [selected] = events(result, "parallel_selected")
    assert {selected.attempt, selected.result} == {"builder", "green"}

    assert {:ok, report} = Build.report(result)
    assert %{"parallel" => %{"cross_check" => cross_check}} = :json.decode(report)
    assert cross_check["status"] == "complete"

    assert Enum.sort_by(cross_check["matrix"], & &1["candidate"]) == [
             %{
               "candidate" => "builder",
               "tests_of" => "sol-medium",
               "tests" => 1,
               "passed" => 1,
               "result" => "ran"
             },
             %{
               "candidate" => "sol-medium",
               "tests_of" => "builder",
               "tests" => 1,
               "passed" => 0,
               "result" => "ran"
             }
           ]
  end

  test "a cross-check over its time budget falls back to the smaller diff", context do
    result = run!(context, "cross-timeout", %{cross_check_ms: 1})

    assert %Result{build: %{status: :landed, landed_sha: sha}} = result
    assert source_at(result, sha) =~ "# revision: sol-medium"
    assert [%{attempt: "sol-medium", result: "green"}] = events(result, "parallel_selected")

    assert {:ok, report} = Build.report(result)
    assert %{"parallel" => %{"cross_check" => %{"status" => "timeout"}}} = :json.decode(report)
  end

  # Both rungs make the acceptance test pass. The builder's larger change adds TinyApp.label/0
  # and a test for it; Sol medium's smaller change has only a test for value/0.
  defp run!(context, name, ladder) do
    builder = [
      write("builder", "  def label, do: \"ready\"\n", "label_test.exs", label_test()),
      done()
    ]

    sol = [write("sol-medium", "", "value_test.exs", value_test()), done()]

    script =
      [ScriptedProvider.answer(:plan, @hard_plan)] ++
        ScriptedProvider.for_model(builder, "gpt-6-luna") ++
        ScriptedProvider.for_model(sol, "gpt-6.1-sol", "medium")

    Ladder.run!(context.tmp_dir, name, script, context.seed, "ladder", ladder)
  end

  defp write(revision, extra, test_name, test_source) do
    source =
      "defmodule TinyApp do\n  # revision: #{revision}\n  def value, do: :ready\n#{extra}end\n"

    shell(
      "cat > lib/tiny_app.ex <<'EOF'\n#{source}EOF\n" <>
        "cat > test/#{test_name} <<'EOF'\n#{test_source}EOF"
    )
  end

  defp label_test do
    """
    defmodule TinyApp.LabelTest do
      use ExUnit.Case, async: true

      test "labels the ready value" do
        assert apply(TinyApp, :label, []) == "ready"
      end
    end
    """
  end

  defp value_test do
    """
    defmodule TinyApp.ValueTest do
      use ExUnit.Case, async: true

      test "returns the ready value" do
        assert TinyApp.value() == :ready
      end
    end
    """
  end
end
