defmodule Kogen.State.IncompleteUsageTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.State
  alias Kogen.State.Run

  test "reported spend from an incomplete generation survives in attempt usage reports", %{
    tmp_dir: tmp
  } do
    run = %Run{
      id: "run",
      dir: tmp,
      slug: "budget",
      intent_sha256: "intent",
      target_branch: "main",
      approval_commit: nil,
      status: :failed,
      landing: nil
    }

    tool = %{
      record_kind: :tool_result,
      tool_result_tokens: 2000,
      original_bytes: 20_000,
      returned_bytes: 8000,
      truncated: true
    }

    model = %{
      record_kind: :model_request,
      stage: :develop,
      attempt: "builder",
      model: "gpt-6-luna",
      effort: "max",
      outcome: :incomplete,
      usage_status: :partial,
      incomplete_reason: "max_output_tokens",
      tokens: %{input: 80, cached_input: 20, output: 12_000, reasoning: 11_000}
    }

    File.write!(Path.join(tmp, "events.jsonl"), "")

    File.write!(
      Path.join(tmp, "requests.jsonl"),
      Enum.map_join([tool, model], "\n", &IO.iodata_to_binary(:json.encode(&1))) <> "\n"
    )

    assert {:ok, usage} = State.attempt_usage(run, "builder")

    assert usage.tokens == %{
             "input" => 80,
             "cached_input" => 20,
             "output" => 12_000,
             "reasoning" => 11_000
           }

    assert {:ok, [partial]} = State.unfinished_usage(run, [])
    assert partial.partial
    assert partial.model == "gpt-6-luna"
    assert partial.effort == "max"
  end
end
