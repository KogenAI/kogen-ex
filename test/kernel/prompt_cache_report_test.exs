defmodule Kogen.Kernel.PromptCacheReportTest do
  use Kogen.Testkit.Case

  alias Kogen.State
  alias Kogen.State.Event
  alias Kogen.Testkit.Proc

  @script Path.expand("../../tools/prompt_cache_report.py", __DIR__)
  @external_resource @script

  test "cache rate weights tokens and excludes cached tokens from input", %{tmp_dir: root} do
    events = [
      %Event{event: "model_stage", tokens: %{"input" => 100, "cached_input" => 900}},
      %Event{event: "model_stage", tokens: %{"input" => 900, "cached_input" => 100}},
      %Event{event: "stage", tokens: %{"input" => 10_000}}
    ]

    assert State.cache_hit_rate(events) == 0.5
    assert State.cache_hit_rate([]) == nil
    assert State.cache_hit_rate([%Event{event: "model_stage", tokens: nil}]) == nil

    rows = [
      row("builder", 1, 1000, 0),
      row("builder", 2, 100, 900),
      row("builder", 3, 30, 970),
      # Repair passes restart the harness turn counter within the same conversation.
      row("builder", 1, 50, 950),
      row("fresh-1", 1, 1000, 0),
      row("fresh-1", 2, 1000, 0),
      row("fresh-1", 3, 1000, 0),
      Map.merge(row("builder", 4, 0, 0), %{"outcome" => "timeout", "tokens" => nil}),
      # Tool receipts share the journal and must not enter the model cache rate.
      Map.merge(row("builder", 9, 1_000_000, 0), %{
        "record_kind" => "tool_result",
        "outcome" => "ok"
      })
    ]

    path = Path.join(root, "requests.jsonl")
    File.write!(path, Enum.map_join(rows, "\n", &Jason.encode!/1))
    result = "python3" |> Proc.cmd!([@script, path], cd: root) |> Jason.decode!()
    [builder, fresh] = result["develop_conversations"]
    assert builder["samples"] == 2
    assert_in_delta builder["median_previous_input_reuse"], 0.96, 0.000001
    assert builder["meets_target"] == true
    assert fresh["median_previous_input_reuse"] == 0.0
    assert fresh["meets_target"] == false
    assert_in_delta result["cache_hit_rate_by_stage"]["develop"], 2820 / 7000, 0.000001
  end

  defp row(conversation, turn, input, cached) do
    %{
      "stage" => "develop",
      "model" => "fixture-model",
      "conversation_id" => conversation,
      "turn" => turn,
      "outcome" => "ok",
      "tokens" => %{"input" => input, "cached_input" => cached}
    }
  end
end
