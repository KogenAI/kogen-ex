defmodule Kogen.E2e.ProviderFallbackTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Resilience.Policy

  @moduletag :e2e
  @moduletag timeout: 300_000

  @same_model %Policy{model_fallback: false, backoff_base_ms: 10, backoff_max_ms: 20}
  @plan "Difficulty: normal\n## Acceptance criteria\n1. TinyApp.value/0 returns :ready."

  setup_all do
    {:ok, seed: Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)}
  end

  test "a ladder lands after repeated overloads without changing model or effort", context do
    script =
      List.duplicate(ScriptedProvider.fail(:plan, :overload), 5) ++
        [ScriptedProvider.answer(:plan, @plan)] ++
        List.duplicate(ScriptedProvider.fail(:develop, :overload), 6) ++
        [
          ScriptedProvider.call(:develop, "shell", %{
            "cmd" => "cat > lib/tiny_app.ex <<'EOF'\n" <> ready_source() <> "EOF"
          }),
          ScriptedProvider.answer(:develop, "Done.")
        ]

    result = Build.run!(context.tmp_dir, script, options(context.seed))

    assert %Result{build: %{status: :landed}, run_status: :landed} = result
    assert Enum.all?(result.provider_requests, &(&1.model == "gpt-6-luna" and &1.effort == "max"))
    refute Enum.any?(result.events, &(&1.event == "model_fallback"))
    assert Enum.any?(requests(result), &(&1["retries"] > @same_model.max_attempts))
    assert {:ok, report} = Build.report(result)
    assert :json.decode(report)["model_fallback"] == false
  end

  for {stage, plan} <- [plan: [], develop: [ScriptedProvider.answer(:plan, @plan)]] do
    test "overloads in #{stage} stop on the budget path without falling back", context do
      stage = unquote(stage)
      plan = unquote(Macro.escape(plan))
      script = plan ++ List.duplicate(ScriptedProvider.fail(stage, :overload), 2_000)
      opts = %{options(context.seed) | ladder: %{wall_ms: 30_000}}

      result = Build.run!(context.tmp_dir, script, opts)

      assert %Result{build: %{status: :failed, reason: :budget_exhausted}} = result
      refute Enum.any?(result.events, &(&1.event == "model_fallback"))
      assert Enum.all?(requests(result), &(&1["model"] == "gpt-6-luna"))

      assert Enum.any?(requests(result), &(&1["outcome"] == "overload"))

      assert {:ok, report} = Build.report(result)
      assert :json.decode(report)["model_fallback"] == false
    end
  end

  defp options(seed) do
    %Options{
      seed_project: seed,
      recipe: "ladder-luna",
      builder_model: "gpt-6-luna",
      builder_effort: "max",
      ladder: %{wall_ms: 120_000},
      resilience: @same_model
    }
  end

  defp ready_source, do: "defmodule TinyApp do\n  def value, do: :ready\nend\n"

  defp requests(%Result{build: %{run_dir: run_dir}}) do
    run_dir
    |> Path.join("requests.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&:json.decode/1)
  end
end
