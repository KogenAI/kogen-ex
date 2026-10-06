defmodule Kogen.Harness.ExchangeStreamRecoveryTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Contracts.ExchangeRequest, as: Request
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.Project
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Opts
  alias Kogen.Provider.ChatGPT
  alias Kogen.Resilience.Policy
  alias Kogen.Testkit.FakeResponsesServer
  alias Kogen.Testkit.HarnessScriptedProvider

  @fast %Policy{backoff_base_ms: 10, backoff_max_ms: 20}

  test "a cut stream continues from its received conversation and preserves the full answer", %{
    tmp_dir: tmp_dir
  } do
    events = [
      %{
        "type" => "response.output_text.delta",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => "I found "
      },
      %{
        "type" => "response.output_item.done",
        "output_index" => 1,
        "item" => %{
          "type" => "reasoning",
          "id" => "rs_1",
          "encrypted_content" => "fake-reasoning",
          "summary" => []
        }
      },
      %{
        "type" => "response.output_item.added",
        "output_index" => 2,
        "item" => %{
          "type" => "function_call",
          "name" => "shell",
          "call_id" => "not-run",
          "arguments" => ""
        }
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 2,
        "delta" => "{unfinished"
      }
    ]

    {url, server} = FakeResponsesServer.start([{:cut, events, :close}, {:ok, "the fix."}])
    opts = opts(tmp_dir, url, %{}, @fast)

    assert {:ok, response} = Exchange.respond(opts, request())
    assert response.text == "I found the fix."
    assert response.tool_calls == []
    assert_receive {:fake_request, 2, body, _at}
    assert Enum.take(body["input"], 3) == request().items

    assert %{"role" => "assistant", "content" => [%{"text" => "I found "}]} =
             Enum.at(body["input"], 3)

    assert Enum.any?(body["input"], &(Map.get(&1, "encrypted_content") == "fake-reasoning"))
    refute Enum.any?(Enum.drop(body["input"], 3), &(Map.get(&1, "type") == "function_call"))
    assert inspect(body["input"]) =~ "NOT executed"
    assert inspect(body["input"]) =~ "{unfinished"
    assert inspect(body["input"]) =~ "Continue the same turn"
    assert Enum.take(response.raw_items, 4) == Enum.drop(body["input"], 3)
    assert [cut, resumed] = records(tmp_dir)
    assert cut["resumed"] == false
    assert is_integer(cut["cut_after_ms"])
    assert resumed["resumed"] == true
    assert resumed["history_items"] > cut["history_items"]
    assert resumed["cut_after_ms"] == :null
    FakeResponsesServer.stop(server)
  end

  test "a watchdog abort keeps partial text for the retry", %{tmp_dir: tmp_dir} do
    delta = %{
      "type" => "response.output_text.delta",
      "output_index" => 0,
      "content_index" => 0,
      "delta" => "Before "
    }

    {url, server} = FakeResponsesServer.start([{:cut, [delta], :hang}, {:ok, "after."}])
    opts = opts(tmp_dir, url, %{}, %{@fast | stream_idle_ms: 500})

    assert {:ok, %{text: "Before after."}} = Exchange.respond(opts, request())
    assert [cut, resumed] = records(tmp_dir)
    assert_receive {:fake_request_ended, 1}
    assert cut["outcome"] == "stall"
    assert cut["cut_after_ms"] >= 500
    assert resumed["resumed"] == true
    FakeResponsesServer.stop(server)
  end

  test "repeated cuts accumulate progress and an EOF carries a reasoning summary", %{
    tmp_dir: tmp_dir
  } do
    first = %{
      "type" => "response.reasoning_summary_text.delta",
      "output_index" => 0,
      "summary_index" => 0,
      "delta" => "The parser is the cause."
    }

    second = %{
      "type" => "response.output_text.delta",
      "output_index" => 0,
      "content_index" => 0,
      "delta" => "Fixed "
    }

    {url, server} =
      FakeResponsesServer.start([{:cut, [first], :end}, {:cut, [second], :close}, {:ok, "it."}])

    opts = opts(tmp_dir, url, %{}, @fast)

    assert {:ok, %{text: "Fixed it."}} = Exchange.respond(opts, request())
    assert_receive {:fake_request, 3, body, _at}
    assert inspect(body["input"]) =~ "The parser is the cause."
    assert inspect(body["input"]) =~ "Fixed "
    assert Enum.map(records(tmp_dir), & &1["resumed"]) == [false, true, true]
    FakeResponsesServer.stop(server)
  end

  test "the total cap applies even before the first byte", %{tmp_dir: tmp_dir} do
    {url, server} = FakeResponsesServer.start([:hang, {:ok, "recovered"}])
    opts = opts(tmp_dir, url, %{first_byte_timeout_ms: 30_000, total_timeout_ms: 500}, @fast)

    assert {:ok, %{text: "recovered"}} = Exchange.respond(opts, request())
    assert [silent, recovered] = records(tmp_dir)
    elapsed = silent["ended_at"] - silent["started_at"]
    assert elapsed >= 500 and elapsed < 5_000
    assert silent["first_byte_at"] == :null
    assert recovered["resumed"] == false
    FakeResponsesServer.stop(server)
  end

  test "keepalive bytes satisfy first-byte and idle caps but remain bounded by the total cap", %{
    tmp_dir: tmp_dir
  } do
    {url, server} = FakeResponsesServer.start([:trickle, {:ok, "recovered"}])

    opts =
      opts(
        tmp_dir,
        url,
        %{first_byte_timeout_ms: 500, total_timeout_ms: 2_000},
        %{@fast | stream_idle_ms: 1_000}
      )

    assert {:ok, %{text: "recovered"}} = Exchange.respond(opts, request())
    assert [silent, recovered] = records(tmp_dir)
    assert silent["outcome"] == "timeout"
    assert is_integer(silent["first_byte_at"])
    assert silent["last_byte_at"] > silent["first_byte_at"]
    assert silent["ended_at"] - silent["last_byte_at"] < 1_000
    assert silent["cut_after_ms"] >= 2_000
    assert recovered["resumed"] == false
    FakeResponsesServer.stop(server)
  end

  test "malformed streamed tool arguments cannot crash recovery", %{tmp_dir: tmp_dir} do
    event = %{
      "type" => "response.output_item.done",
      "output_index" => 0,
      "item" => %{"type" => "function_call", "name" => "shell", "arguments" => %{}}
    }

    {url, server} = FakeResponsesServer.start([{:cut, [event], :close}, {:ok, "recovered"}])
    opts = opts(tmp_dir, url, %{}, @fast)

    assert {:ok, %{text: "recovered", tool_calls: []}} = Exchange.respond(opts, request())
    assert_receive {:fake_request, 2, body, _at}
    assert body["input"] == request().items
    assert [_, %{"resumed" => false}] = records(tmp_dir)
    FakeResponsesServer.stop(server)
  end

  @tag timeout: 150_000
  test "a scripted provider with no bytes is aborted at 120 seconds and retried", %{
    tmp_dir: tmp_dir
  } do
    response = %ModelResponse{
      id: "resp_recovered",
      text: "recovered",
      tool_calls: [],
      usage: %{},
      raw_items: []
    }

    provider = HarnessScriptedProvider.start([:hang, response])

    opts = %{
      opts(tmp_dir, "unused", %{}, @fast)
      | provider_mod: HarnessScriptedProvider,
        provider_config: provider
    }

    assert {:ok, %{text: "recovered"}} =
             Exchange.respond(opts, %{request() | remaining_ms: 140_000})

    assert [silent, recovered] = records(tmp_dir)
    elapsed = silent["ended_at"] - silent["started_at"]
    assert elapsed >= 120_000 and elapsed < 125_000
    assert silent["outcome"] == "timeout"
    assert silent["first_byte_at"] == :null
    assert silent["cut_after_ms"] == :null
    assert silent["resumed"] == false
    assert recovered["retries"] == 1
    assert recovered["resumed"] == false
    assert length(HarnessScriptedProvider.requests(provider)) == 2
  end

  defp records(tmp_dir) do
    tmp_dir
    |> Path.join("run/requests.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&:json.decode/1)
  end

  defp request do
    %Request{
      stage: :develop,
      turn: 3,
      model: "gpt-6-luna",
      effort: "max",
      instructions: "Build it.",
      items: [
        %{"role" => "user", "content" => []},
        %{"type" => "function_call", "call_id" => "c1", "name" => "shell", "arguments" => "{}"},
        %{"type" => "function_call_output", "call_id" => "c1", "output" => "0123456789"}
      ],
      tool_names: [],
      remaining_ms: 60_000
    }
  end

  defp opts(tmp_dir, url, config_overrides, policy) do
    workdir = Path.join(tmp_dir, "project")
    File.mkdir_p!(workdir)

    config =
      Map.merge(
        %ChatGPT.Config{
          access_token: "test-token",
          account_id: "test-account",
          endpoint: url,
          timeout_ms: 30_000
        },
        config_overrides
      )

    %Opts{
      workdir: workdir,
      run_dir: Path.join(tmp_dir, "run"),
      project: %Project{
        root: workdir,
        name: "exchange-request-journal-test",
        checks: [],
        setup: [],
        fix: [],
        diagnose: [],
        protected_paths: [],
        domains: %{}
      },
      provider_mod: ChatGPT,
      provider_config: config,
      proc_mod: Kogen.Proc,
      resilience: policy,
      request_tags: %{attempt: "sol-medium", rung: "sol-medium"}
    }
  end
end
