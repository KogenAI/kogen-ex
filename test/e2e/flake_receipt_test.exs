defmodule Kogen.E2e.FlakeReceiptTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider

  @moduletag :e2e
  @moduletag timeout: 120_000

  test "a same-seed test flake that fails on base is excused and reported", context do
    parent = scenario_parent(context, "flake-policy")
    marker = Path.join(parent, "candidate-test-ran")

    project_config = """
    name: tiny_app
    checks:
      - name: tests
        argv: [mix, test]
        timeout_ms: 60000
    fix: []
    env:
      KOGEN_FLAKE_MARKER: "#{marker}"
    domains:
      kernel: [lib]
    """

    seed_project =
      Build.prepare_seed!(parent,
        project_config: project_config,
        extra_files: %{"test/flaky_test.exs" => flaky_test_source()}
      )

    result = Build.run!(parent, flake_script(), %Options{seed_project: seed_project})

    assert %Result{build: %{status: :landed}} = result
    assert [flake] = Enum.filter(result.events, &(&1.event == "flake_excused"))
    assert [test_id] = flake.test_ids
    assert test_id =~ "test/flaky_test.exs:"
    assert is_integer(flake.seed)
    assert flake.seed >= 0

    assert Enum.any?(result.events, &(&1.event == "scope_warning" and &1.path == "README.md"))

    assert {:ok, report} = Build.report(result)

    decoded = :json.decode(report)
    assert [%{"test_ids" => [^test_id], "seed" => seed}] = decoded["excused_flakes"]
    assert seed == flake.seed
    assert [evidence] = decoded["flake_evidence"]
    assert evidence["classification"] == "base_flake"
    assert evidence["candidate"]["exit_status"] != 0
    assert evidence["candidate_retry"]["exit_status"] == 0
    assert evidence["base"]["exit_status"] != 0
    assert evidence["base"]["timed_out"] == false
    assert evidence["base_failed_test_ids"] == [test_id]
    assert Integer.to_string(seed) in evidence["candidate"]["argv"]
    assert Integer.to_string(seed) in evidence["base"]["argv"]
    assert evidence["candidate_snapshot"]["status"] == "captured"
    assert evidence == evidence["path"] |> File.read!() |> JSON.decode!()
    assert decoded["flake_metrics"]["retry_cost_ms"] > 0
    assert decoded["flake_metrics"]["leaked_candidate_flakes"] == 0
    assert decoded["flake_fix_intents"] == []
  end

  defp scenario_parent(context, name) do
    parent = Path.join(context.tmp_dir, name)
    File.mkdir_p!(parent)
    parent
  end

  defp flake_script do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(
        :develop,
        "lib/tiny_app.ex",
        "defmodule TinyApp do\n  def value, do: :ready\nend\n"
      ),
      ScriptedProvider.write(:develop, "README.md", "Out-of-scope note.\n"),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]
  end

  defp flaky_test_source do
    """
    defmodule TinyApp.FlakyTest do
      use ExUnit.Case, async: true

      test "candidate run flakes once before the base rerun fails" do
        marker = System.fetch_env!("KOGEN_FLAKE_MARKER")

        if TinyApp.value() == :ready do
          if File.exists?(marker) do
            assert true
          else
            File.write!(marker, "seen")
            flunk("injected one-time Candidate test flake")
          end
        else
          if File.exists?(marker), do: flunk("injected base failure after Candidate retry")
          assert TinyApp.value() == :base
        end
      end
    end
    """
  end
end
