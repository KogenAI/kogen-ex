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
