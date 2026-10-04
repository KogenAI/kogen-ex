defmodule Kogen.Provider.FakeTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT.Codec
  alias Kogen.Provider.Fake

  test "replays the committed text and function-call recordings" do
    text_path = Path.join(__DIR__, "fixtures/gpt-6-luna-text.jsonl")
    tool_path = Path.join(__DIR__, "fixtures/gpt-6-luna-tool_call.jsonl")
    assert File.regular?(text_path)
    assert File.regular?(tool_path)
    assert {:ok, config} = Fake.config([text_path, tool_path])

    assert {:ok, text_response} = Fake.respond(config, recorded_request("text"))
    assert text_response.text != ""

    assert {:ok, tool_response} = Fake.respond(config, recorded_request("tool_call"))
    assert length(tool_response.tool_calls) == 1
    assert Enum.any?(tool_response.raw_items, &(&1["type"] == "function_call"))
  end

  test "replays a function call and its tool-result continuation", %{tmp_dir: tmp_dir} do
    first_request = request()
    call = function_item()
    first_items = [call, message("Thinking")]

    first_path =
      fixture(tmp_dir, "call.jsonl", first_request, response_events("resp_call", first_items))

    output = %{
      "type" => "function_call_output",
      "call_id" => "call_roundtrip",
      "output" => "created"
    }

    next_request = %{first_request | input: first_request.input ++ first_items ++ [output]}
    next_item = message("Finished")

    next_path =
      fixture(tmp_dir, "final.jsonl", next_request, response_events("resp_final", [next_item]))

    assert {:ok, fake} = Fake.config([first_path, next_path])

    assert {:ok, call_response} = Fake.respond(fake, first_request)
    assert [%{id: "call_roundtrip", name: "write_file"}] = call_response.tool_calls
    assert {:ok, final_response} = Fake.respond(fake, next_request)
    assert final_response.text == "Finished"
    assert List.last(next_request.input) == output
  end

  test "fails loudly when there is no exact fixture match", %{tmp_dir: tmp_dir} do
    path = fixture(tmp_dir, "one.jsonl", request(), [message("Only fixture")])
    assert {:ok, fake} = Fake.config([path])
    unmatched = %{request() | model: "gpt-6.1-sol"}

    assert {:error, %ProviderError{class: :malformed, message: message}} =
             Fake.respond(fake, unmatched)

    assert message =~ "No recorded provider response"
  end

  test "cache routing keys do not change fixture fingerprints" do
    request = request()
    assert {:ok, original} = Codec.request_fingerprint(request)

    assert {:ok, with_cache_key} =
             Codec.request_fingerprint(%{request | prompt_cache_key: String.duplicate("b", 64)})

    assert with_cache_key == original
  end

  test "replays provider error events with their classified error", %{tmp_dir: tmp_dir} do
    error = %{"type" => "error", "error" => %{"code" => "usage_limit_reached"}}
    path = fixture(tmp_dir, "error.jsonl", request(), [error])
    assert {:ok, fake} = Fake.config([path])

    assert {:error, %ProviderError{class: :usage_limit}} = Fake.respond(fake, request())
  end

  test "committed recordings contain event data only, without auth headers or bearer tokens" do
    files = Path.wildcard(Path.join(__DIR__, "fixtures/*.jsonl"))
    assert length(files) >= 2

    Enum.each(files, fn path ->
      body = path |> File.read!() |> String.downcase()
      refute String.contains?(body, "authorization")
      refute String.contains?(body, "bearer ")
      refute String.contains?(body, "access_token")
    end)
  end

  defp fixture(directory, filename, request, events) do
    {:ok, fingerprint} = Codec.request_fingerprint(request)
    metadata = %{"kind" => "recording", "model" => request.model, "request_sha256" => fingerprint}

    rows = [metadata | Enum.map(events, &%{"kind" => "sse", "data" => encode(&1)})]
    path = Path.join(directory, filename)
    File.write!(path, Enum.map_join(rows, "\n", &encode/1) <> "\n")
    path
  end

  defp recorded_request("tool_call") do
    base = request()

    %{
      base
      | instructions: "Call the echo_phrase function exactly once with phrase set to recorded.",
        input: [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "Use the function tool now."}]
          }
        ],
        tools: [tool_definition()]
    }
  end

  defp recorded_request(_scenario) do
    base = request()

    %{
      base
      | instructions: "Answer exactly with the word recorded.",
        input: [
          %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Reply now."}]}
        ],
        tools: []
    }
  end

  defp request do
    %ModelRequest{
      model: "gpt-6-luna",
      effort: "low",
      instructions: "Do the task.",
      input: [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "hello"}]}],
      tools: [tool_definition()],
      previous_response_id: nil
    }
  end

  defp tool_definition do
    %{
      "type" => "function",
      "name" => "echo_phrase",
      "description" => "Echo a phrase supplied by the user.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"phrase" => %{"type" => "string"}},
        "required" => ["phrase"],
        "additionalProperties" => false
      },
      "strict" => false
    }
  end

  defp function_item do
    %{
      "id" => "fc_roundtrip",
      "type" => "function_call",
      "call_id" => "call_roundtrip",
      "name" => "write_file",
      "arguments" => ~s({"path":"a"})
    }
  end

  defp message(text),
    do: %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }

  defp completed(id, items) do
    %{
      "id" => id,
      "status" => "completed",
      "output" => items,
      "usage" => %{"input_tokens" => 2, "output_tokens" => 1}
    }
  end

  defp response_events(id, items) do
    item_events = Enum.map(items, &%{"type" => "response.output_item.done", "item" => &1})
    item_events ++ [%{"type" => "response.completed", "response" => completed(id, items)}]
  end

  defp encode(value), do: value |> :json.encode() |> IO.iodata_to_binary()
end
