defmodule Kogen.E2e.ProviderStallTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.Ladder
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Resilience.Policy

  @moduletag :e2e
  @moduletag timeout: 300_000

  @fast_idle %Policy{stream_idle_ms: 2_000, backoff_base_ms: 10, backoff_max_ms: 20}
  @plan "Difficulty: normal\n## Acceptance criteria\n1. TinyApp.value/0 returns :ready."

  setup_all do
    {:ok, seed: Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)}
  end

  test "a Build whose develop requests stall again and again still lands", context do
    source = "defmodule TinyApp do\n  def value, do: :ready\nend\n"

    script = [
      ScriptedProvider.stall(:develop),
      ScriptedProvider.stall(:develop),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source),
      ScriptedProvider.stall(:develop),
      ScriptedProvider.answer(:develop, "Done.")
    ]

    result =
      Build.run!(parent(context, "stalls"), script, %Options{
        seed_project: context.seed,
        recipe: "direct",
        resilience: @fast_idle
      })

    assert %Result{build: %{status: :landed}, run_status: :landed} = result

    assert Enum.map(requests(result), &{&1["turn"], &1["outcome"], &1["retries"]}) == [
             {1, "stall", 0},
             {1, "stall", 1},
             {1, "ok", 2},
             {2, "stall", 0},
             {2, "ok", 1}
           ]

    for stalled <- Enum.filter(requests(result), &(&1["outcome"] == "stall")) do
      assert is_integer(stalled["first_byte_at"])
      assert stalled["idle_ms"] >= 2_000 and stalled["idle_ms"] < 15_000
    end
  end

  test "a Build that stalls until its budget ends finishes on the deadline path", context do
    script = [ScriptedProvider.answer(:plan, @plan)] ++ List.duplicate(stall(), 200)

    result =
      Build.run!(parent(context, "budget"), script, %Options{
        seed_project: context.seed,
        recipe: "ladder",
        builder_model: "gpt-6-luna",
        builder_effort: "max",
        ladder: %{wall_ms: 30_000},
        resilience: @fast_idle
      })

    assert %Result{build: %{status: :failed, reason: :budget_exhausted} = build} = result
    refute match?(%{class: :provider}, build.failure)
    assert Enum.count(requests(result), &(&1["outcome"] == "stall")) >= 3
    assert [%{rung: "builder", result: "failed"} | _rest] = Ladder.events(result, "rung_finished")
    assert Ladder.events(result, "stage_failure") == []
    refute Enum.any?(result.events, &(inspect(&1) =~ "provider_retries_exhausted"))
  end

  defp stall, do: ScriptedProvider.stall(:develop)

  defp parent(context, name) do
    path = Path.join(context.tmp_dir, name)
    File.mkdir_p!(path)
    path
  end

  defp requests(%Result{build: %{run_dir: run_dir}}) do
    run_dir
    |> Path.join("requests.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&:json.decode/1)
    |> Enum.filter(&(&1["record_kind"] == "model_request"))
  end
end
