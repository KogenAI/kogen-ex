defmodule Kogen.Harness.IncompleteBuilderTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ProviderError
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Provider.ChatGPT
  alias Kogen.Testkit.FakeResponsesServer

  test "a capped reasoning-heavy response journals partial spend and never executes partial tool calls",
       %{tmp_dir: tmp} do
    usage = %{
      "input_tokens" => 100,
      "input_tokens_details" => %{"cached_tokens" => 20},
      "output_tokens" => 12_000,
      "output_tokens_details" => %{"reasoning_tokens" => 11_000}
    }

    {opts, server} = setup_response(tmp, "response.incomplete", "incomplete", usage)

    assert {:error, %ProviderError{class: :incomplete, incomplete_reason: "max_output_tokens"}} =
             Harness.develop(opts, "Build it.", nil, nil)

    refute File.exists?(Path.join(opts.workdir, "should-not-execute"))
    assert_receive {:fake_request, 1, body, _at}
    assert body["max_output_tokens"] == 12_000
    assert body["reasoning"] == %{"effort" => "max"}
    assert [record] = records(opts)
    assert record["outcome"] == "incomplete"
    assert record["usage_status"] == "partial"
    assert record["incomplete_reason"] == "max_output_tokens"
    assert record["tokens"]["output"] == 12_000
    assert record["tokens"]["reasoning"] == 11_000
    assert record["request_settings"]["model_generation_tokens"] == 12_000
    assert record["request_settings"]["tool_result_tokens"] == 2_000
    FakeResponsesServer.stop(server)
  end

  test "incomplete completion envelopes keep unknown usage unknown and do not execute commands",
       %{tmp_dir: tmp} do
    {opts, server} = setup_response(tmp, "response.completed", "incomplete", nil)

    assert {:error, %ProviderError{class: :incomplete}} =
             Harness.develop(opts, "Build it.", nil, nil)

    refute File.exists?(Path.join(opts.workdir, "should-not-execute"))
    assert [record] = records(opts)
    assert record["outcome"] == "incomplete"
    assert record["tokens"] == :null
    assert record["usage_status"] == "unknown"
    FakeResponsesServer.stop(server)
  end

  test "a completed response cannot execute an item still marked in progress", %{tmp_dir: tmp} do
    usage = %{"input_tokens" => 1, "output_tokens" => 1}
    {opts, server} = setup_response(tmp, "response.completed", "completed", usage)
    opts = %{opts | resilience: %{opts.resilience | max_attempts: 1}}

    assert {:error, %ProviderError{class: :malformed}} =
             Harness.develop(opts, "Build it.", nil, nil)

    refute File.exists?(Path.join(opts.workdir, "should-not-execute"))
    FakeResponsesServer.stop(server)
  end

  defp setup_response(tmp, event_type, status, usage) do
    item = %{
      "type" => "function_call",
      "status" => "in_progress",
      "call_id" => "partial",
      "name" => "shell",
      "arguments" => ~s({"cmd":"touch should-not-execute"})
    }

    response = %{
      "id" => "response-capped",
      "status" => status,
      "output" => [item],
      "usage" => usage,
      "incomplete_details" => %{"reason" => "max_output_tokens"}
    }

    frames =
      frame(%{"type" => "response.output_item.done", "item" => item}) <>
        frame(%{"type" => event_type, "response" => response})

    {url, server} = FakeResponsesServer.start([{:status, 200, frames}])
    opts = response_opts(tmp, url)
    {opts, server}
  end

  defp response_opts(tmp, url) do
    workdir = Path.join(tmp, "candidate")
    File.mkdir_p!(workdir)

    opts = %Opts{
      workdir: workdir,
      run_dir: Path.join(tmp, "run"),
      proc_mod: Kogen.Proc,
      provider_mod: ChatGPT,
      builder_tools: :shell,
      provider_config: %ChatGPT.Config{
        endpoint: url,
        timeout_ms: 30_000,
        access_token: "test-token",
        account_id: "test-account",
        model_generation_cap_supported: true
      },
      project: %Project{
        root: workdir,
        name: "budget",
        checks: [],
        setup: [],
        fix: [],
        diagnose: [],
        protected_paths: [],
        domains: %{},
        build: %{tool_result_tokens: 2_000, model_generation_tokens: 12_000}
      }
    }

    opts
  end

  defp frame(event), do: "data: " <> IO.iodata_to_binary(:json.encode(event)) <> "\n\n"

  defp records(opts),
    do:
      opts.run_dir
      |> Path.join("requests.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)
end
