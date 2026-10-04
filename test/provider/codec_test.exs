defmodule Kogen.Provider.ChatGPT.CodecTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT.Codec

  test "encodes the Responses request without rejected max output tokens" do
    assert {:ok, encoded} = Codec.encode_request(request())
    body = :json.decode(encoded)

    assert body["model"] == "gpt-6-luna"
    assert body["reasoning"] == %{"effort" => "low"}
    assert body["store"] == false
    assert body["stream"] == true
    assert body["include"] == ["reasoning.encrypted_content"]
    refute Map.has_key?(body, "max_output_tokens")
  end

  test "encodes the prompt cache key for stateless ChatGPT requests" do
    key = String.duplicate("a", 64)
    request = %{request() | prompt_cache_key: key}

    for mode <- [:codex, :siwc] do
      assert {:ok, encoded} = Codec.encode_request(request, mode)
      body = :json.decode(encoded)

      assert body["prompt_cache_key"] == key
      assert body["store"] == false
      refute Map.has_key?(body, "previous_response_id")
    end
  end

  test "encodes ChatGPT plan requests with documented stateless additional tools" do
    tool = %{
      "type" => "function",
      "name" => "read",
      "parameters" => %{"type" => "object", "properties" => %{}, "required" => []}
    }

    assert {:ok, encoded} =
             Codec.encode_request(
               %{request() | tools: [tool], previous_response_id: "resp_ignored"},
               :siwc
             )

    body = :json.decode(encoded)

    assert [%{"type" => "additional_tools", "role" => "developer", "tools" => [^tool]} | _rest] =
             body["input"]

    assert body["store"] == false
    assert body["stream"] == true
    refute Map.has_key?(body, "previous_response_id")
    refute Map.has_key?(body, "include")
  end

  test "decodes fragmented ordered output items, tool calls, and usage" do
    items = [reasoning_item(), function_item(), message_item()]
    events = Enum.map(items, &item_done/1) ++ [completed(items)]
    body = Enum.map_join(events, &frame/1)

    stream =
      body
      |> byte_chunks()
      |> Enum.reduce(Codec.new_stream(), &Codec.feed(&2, &1))

    assert {:ok, response} = Codec.finish(stream)
    assert response.text == "done"
    assert response.raw_items == items

    assert [%{id: "call_1", name: "write_file", arguments: %{"path" => "a"}}] =
             response.tool_calls

    assert response.usage == %{input: 8, cached_input: 2, output: 5, reasoning: 3}
  end

  test "requires response.completed before accepting a stream" do
    stream = Codec.feed(Codec.new_stream(), frame(item_done(message_item())))

    assert {:error, %ProviderError{class: :malformed}} = Codec.finish(stream)
  end

  test "classifies usage-limit and overload error events" do
    usage_event = %{
      "type" => "error",
      "error" => %{"code" => "subscription_sharing_usage_limit_exceeded"}
    }

    overload_event = %{
      "type" => "response.failed",
      "response" => %{"error" => %{"code" => "server_is_overloaded"}}
    }

    assert {:error, %ProviderError{class: :usage_limit, message: message}} =
             Codec.new_stream() |> Codec.feed(frame(usage_event)) |> Codec.finish()

    assert message =~ "Manage usage"

    assert {:error, %ProviderError{class: :overload}} =
             Codec.new_stream() |> Codec.feed(frame(overload_event)) |> Codec.finish()
  end

  test "classifies malformed JSON as malformed" do
    stream = Codec.feed(Codec.new_stream(), "data: {bad json}\n\n")

    assert {:error, %ProviderError{class: :malformed}} = Codec.finish(stream)
  end

  defp request do
    %ModelRequest{
      model: "gpt-6-luna",
      effort: "low",
      instructions: "Do the task.",
      input: [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "hello"}]}],
      tools: [],
      previous_response_id: nil
    }
  end

  defp reasoning_item do
    %{"id" => "rs_1", "type" => "reasoning", "encrypted_content" => "opaque", "summary" => []}
  end

  defp function_item do
    %{
      "id" => "fc_1",
      "type" => "function_call",
      "call_id" => "call_1",
      "name" => "write_file",
      "arguments" => ~s({"path":"a"})
    }
  end

  defp message_item do
    %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "done"}]
    }
  end

  defp item_done(item), do: %{"type" => "response.output_item.done", "item" => item}

  defp completed(items) do
    %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_1",
        "status" => "completed",
        "output" => items,
        "usage" => %{
          "input_tokens" => 10,
          "input_tokens_details" => %{"cached_tokens" => 2},
          "output_tokens" => 5,
          "output_tokens_details" => %{"reasoning_tokens" => 3}
        }
      }
    }
  end

  defp frame(event), do: "event: #{event["type"]}\r\ndata: #{encode(event)}\r\n\r\n"
  defp encode(event), do: event |> :json.encode() |> IO.iodata_to_binary()
  defp byte_chunks(body), do: for(<<byte <- body>>, do: <<byte>>)
end
