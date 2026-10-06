defmodule Kogen.Harness.ExchangeRequestJournalTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ProviderError
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request
  alias Kogen.Harness.Opts
  alias Kogen.Provider.ChatGPT
  alias Kogen.Resilience.Policy
  alias Kogen.Testkit.FakeResponsesServer

  @fast %Policy{backoff_base_ms: 10, backoff_max_ms: 20}

  test "a successful request leaves one record with timings, usage and history size", %{
    tmp_dir: tmp_dir
  } do
    {url, server} = FakeResponsesServer.start([{:ok, "done"}])
    opts = opts(tmp_dir, url, %{}, @fast)

    assert {:ok, %{text: "done"}} = Exchange.respond(opts, request())

    assert [record] = records(tmp_dir)

    assert %{
             "stage" => "develop",
             "turn" => 3,
             "attempt" => "sol-medium",
             "rung" => "sol-medium",
             "model" => "gpt-6-luna",
             "effort" => "max",
             "outcome" => "ok",
             "retries" => 0,
             "history_items" => 3,
             "tool_output_bytes" => 10,
             "tokens" => %{"input" => 1, "cached_input" => 0, "output" => 1}
           } = record

    assert record["request_settings"] == %{
             "adapter" => "responses",
             "adapter_version" => "codex-0.160.0/kogen-1",
             "text_verbosity" => "low",
             "reasoning_summary" => "none",
             "reasoning_context" => :null,
             "tool_choice" => "auto",
             "parallel_tool_calls" => false,
             "model_generation_tokens" => :null,
             "tool_result_tokens" => 2_000,
             "session_id" => record["request_settings"]["session_id"]
           }

    assert_receive {:fake_request, 1, body, _at}
    assert body["text"] == %{"verbosity" => "low"}
    assert body["reasoning"] == %{"effort" => "max"}
    assert record["history_bytes"] > record["tool_output_bytes"]
    assert record["started_at"] <= record["first_byte_at"]
    assert record["first_byte_at"] <= record["ended_at"]
    FakeResponsesServer.stop(server)
  end

  test "a request that never gets a first byte is recorded as a timeout with no first byte", %{
    tmp_dir: tmp_dir
  } do
    {url, server} = FakeResponsesServer.start([:hang])
    policy = %{@fast | max_attempts: 1}
    opts = opts(tmp_dir, url, %{first_byte_timeout_ms: 2_000, timeout_ms: 30_000}, policy)

    assert {:error, %ProviderError{class: :timeout}} =
             Exchange.respond(opts, %{request() | remaining_ms: :infinity})

    assert [record] = records(tmp_dir)

    assert %{"outcome" => "timeout", "retries" => 0, "first_byte_at" => :null, "tokens" => :null} =
             record

    waited = record["ended_at"] - record["started_at"]
    assert waited >= 2_000 and waited < 15_000
    FakeResponsesServer.stop(server)
  end

  test "a retried request leaves a record per attempt with its retry count", %{tmp_dir: tmp_dir} do
    overloaded = {:status, 503, ~s({"error":{"message":"overloaded"}})}
    {url, server} = FakeResponsesServer.start([overloaded, {:ok, "recovered"}])
    opts = opts(tmp_dir, url, %{}, @fast)

    assert {:ok, %{text: "recovered"}} = Exchange.respond(opts, request())

    assert [first, second] = records(tmp_dir)
    assert {first["outcome"], first["retries"], first["tokens"]} == {"overload", 0, :null}
    assert {second["outcome"], second["retries"]} == {"ok", 1}
    assert second["started_at"] >= first["ended_at"]
    FakeResponsesServer.stop(server)
  end

  test "a stalled stream is recorded as a stall with its last byte and idle gap", %{
    tmp_dir: tmp_dir
  } do
    {url, server} = FakeResponsesServer.start([:stall, {:ok, "recovered"}])
    opts = opts(tmp_dir, url, %{timeout_ms: 30_000}, %{@fast | stream_idle_ms: 2_000})

    assert {:ok, %{text: "recovered"}} = Exchange.respond(opts, request())

    assert [stalled, recovered] = records(tmp_dir)
    assert %{"outcome" => "stall", "retries" => 0, "tokens" => :null} = stalled
    assert stalled["first_byte_at"] == stalled["last_byte_at"]
    assert stalled["idle_ms"] == stalled["ended_at"] - stalled["last_byte_at"]
    assert stalled["idle_ms"] >= 2_000 and stalled["idle_ms"] < 15_000
    assert %{"outcome" => "ok", "retries" => 1, "idle_ms" => :null} = recovered
    FakeResponsesServer.stop(server)
  end

  test "the deadline cutting off a request is recorded too", %{tmp_dir: tmp_dir} do
    {url, server} = FakeResponsesServer.start([:hang])
    opts = opts(tmp_dir, url, %{timeout_ms: 30_000}, @fast)

    assert {:error, %ProviderError{class: :timeout}} =
             Exchange.respond(opts, %{request() | remaining_ms: 2_000})

    assert [%{"outcome" => "timeout", "first_byte_at" => :null}] = records(tmp_dir)
    FakeResponsesServer.stop(server)
  end

  test "Lite selection is measured and stable across identical builder attempts", %{
    tmp_dir: tmp_dir
  } do
    {url, server} = FakeResponsesServer.start([{:ok, "done"}])
    opts = opts(tmp_dir, url, %{}, @fast)
    opts = %{opts | project: %{opts.project | build: %{luna_provider_mode: :lite}}}
    assert {:ok, _response} = Exchange.respond(opts, request())
    assert {:ok, _response} = Exchange.respond(opts, request())
    assert_receive {:fake_request, 1, first, _at}
    assert_receive {:fake_request, 2, second, _at}
    assert first == second
    assert first["reasoning"] == %{"effort" => "max", "context" => "all_turns"}
    assert first["instructions"] == ""
    refute Map.has_key?(first, "tools")
    assert [record, again] = records(tmp_dir)
    assert record["request_settings"] == again["request_settings"]
    assert record["request_settings"]["adapter"] == "lite"
    FakeResponsesServer.stop(server)
  end

  test "Sol-high planning preserves its conventional request settings", %{tmp_dir: tmp_dir} do
    {url, server} = FakeResponsesServer.start([{:ok, "plan"}])
    opts = opts(tmp_dir, url, %{}, @fast)
    opts = %{opts | project: %{opts.project | build: %{luna_provider_mode: :lite}}}
    request = %{request() | model: "gpt-6.1-sol", effort: "high", stage: :plan}
    assert {:ok, _response} = Exchange.respond(opts, request)
    assert_receive {:fake_request, 1, body, _at}
    assert body["model"] == "gpt-6.1-sol"
    assert body["reasoning"] == %{"effort" => "high"}
    refute Map.has_key?(body, "text")
    assert [record] = records(tmp_dir)
    assert record["request_settings"]["adapter"] == "responses"
    FakeResponsesServer.stop(server)
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
