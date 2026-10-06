defmodule Kogen.Provider.ChatGPT.TransportTest do
  use ExUnit.Case, async: true

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT

  # Servers hand the captured request to the test process only after replying, so a
  # loaded machine can deliver it long after the client returned.
  @receive_ms 10_000

  test "streams fragmented SSE over OTP httpc with the required Responses body" do
    item = %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "ok"}]
    }

    body = sse(%{"type" => "response.completed", "response" => completed("resp_1", [item])})
    {url, server} = start_server(200, body, :chunked)
    config = config(url)

    assert {:ok, response} = ChatGPT.respond(config, request())
    assert response.text == "ok"
    assert_receive {:captured_request, request_bytes}, @receive_ms
    request_text = IO.iodata_to_binary(request_bytes)
    [headers, request_body] = :binary.split(request_text, "\r\n\r\n")
    encoded = :json.decode(request_body)

    assert String.downcase(headers) =~ "authorization: bearer test-token"
    assert encoded["model"] == "gpt-6-luna"
    assert encoded["store"] == false
    assert encoded["stream"] == true
    assert encoded["include"] == ["reasoning.encrypted_content"]
    refute Map.has_key?(encoded, "max_output_tokens")
    assert is_pid(server)
  end

  test "a slowly progressing SSE response is governed by its idle timeout" do
    item = %{
      "id" => "msg_slow",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "still progressing"}]
    }

    body = sse(%{"type" => "response.completed", "response" => completed("resp_slow", [item])})
    {url, _server} = start_server(200, body, :slow_chunked)
    config = %{config(url) | timeout_ms: 2_000}
    started = System.monotonic_time(:millisecond)

    assert {:ok, response} = ChatGPT.respond(config, request())

    assert response.text == "still progressing"
    assert System.monotonic_time(:millisecond) - started > config.timeout_ms
  end

  test "classifies HTTP auth, usage-limit shapes, and overloaded failures" do
    responses = [
      {401, ~s({"detail":"login rejected"}), :login},
      {429, ~s({"detail":"usage limit reached"}), :usage_limit},
      {429, ~s({"error":{"code":"subscription_sharing_usage_limit_exceeded"}}), :usage_limit},
      {503, ~s({"error":{"code":"subscription_sharing_usage_unavailable"}}), :overload},
      {503, ~s({"error":{"message":"overloaded"}}), :overload}
    ]

    Enum.each(responses, fn {status, body, expected_class} ->
      {url, _server} = start_server(status, body, :normal)

      assert {:error, %ProviderError{class: ^expected_class} = error} =
               ChatGPT.respond(config(url), request())

      if expected_class == :usage_limit, do: assert(error.message =~ "Manage usage")

      assert_receive {:captured_request, _request}, @receive_ms
    end)
  end

  test "classifies a stream that ends without response.completed as malformed" do
    partial = sse(%{"type" => "response.output_item.done", "item" => %{"type" => "message"}})
    {url, _server} = start_server(200, partial, :chunked)

    assert {:error, %ProviderError{class: :malformed}} = ChatGPT.respond(config(url), request())
    assert_receive {:captured_request, _request}, @receive_ms
  end

  test "classifies an HTTP request timeout" do
    {url, server} = start_hanging_server()
    config = %{config(url) | timeout_ms: 2_000}

    assert {:error, %ProviderError{class: :timeout}} = ChatGPT.respond(config, request())
    send(server, :release)
    assert_receive {:captured_request, _request}, @receive_ms
  end

  test "proxy URLs with credentials fail with a clear transport error" do
    config = %{
      config("https://chatgpt.com/responses")
      | proxy_env: %{"https_proxy" => "http://test-user:test-password@127.0.0.1:8080"}
    }

    assert {:error, %ProviderError{class: :transport, message: message}} =
             ChatGPT.respond(config, request())

    assert message =~ "proxy URLs with credentials are not supported"
  end

  defp config(url) do
    %ChatGPT.Config{
      access_token: "test-token",
      account_id: "test-account",
      endpoint: url,
      timeout_ms: 2_000
    }
  end

  defp request do
    %ModelRequest{
      model: "gpt-6-luna",
      effort: "low",
      instructions: "Answer with one word.",
      input: [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "ok"}]}],
      tools: [],
      previous_response_id: nil
    }
  end

  defp completed(id, items) do
    %{
      "id" => id,
      "status" => "completed",
      "output" => items,
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }
  end

  defp sse(event), do: "event: #{event["type"]}\r\ndata: #{encode(event)}\r\n\r\n"
  defp encode(value), do: value |> :json.encode() |> IO.iodata_to_binary()

  defp start_server(status, body, mode) do
    {:ok, listener, url} = listen()
    parent = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        request = receive_request(socket, <<>>)
        send_response(socket, status, body, mode)
        send(parent, {:captured_request, request})
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {url, server}
  end

  defp start_hanging_server do
    {:ok, listener, url} = listen()
    parent = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        send(parent, {:captured_request, receive_request(socket, <<>>)})

        receive do
          :release -> :ok
        end

        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {url, server}
  end

  defp listen do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    {:ok, listener, "http://127.0.0.1:#{port}/responses"}
  end

  defp receive_request(socket, buffer) do
    if request_complete?(buffer) do
      buffer
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, @receive_ms)
      receive_request(socket, buffer <> chunk)
    end
  end

  defp request_complete?(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [headers, body] -> byte_size(body) >= content_length(headers)
      _ -> false
    end
  end

  defp content_length(headers) do
    headers
    |> :binary.split("\r\n", [:global])
    |> Enum.find_value(0, fn line ->
      case :binary.split(String.downcase(line), ":", [:global]) do
        ["content-length", value] -> String.to_integer(String.trim(value))
        _ -> nil
      end
    end)
  end

  defp send_response(socket, status, body, :chunked) do
    header =
      "HTTP/1.1 #{status} OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"

    :ok = :gen_tcp.send(socket, header)

    Enum.each(chunks(body, 11), fn chunk ->
      :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])
    end)

    :gen_tcp.send(socket, "0\r\n\r\n")
  end

  defp send_response(socket, status, body, :slow_chunked) do
    header =
      "HTTP/1.1 #{status} OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"

    :ok = :gen_tcp.send(socket, header)

    Enum.each(chunks(body, 18), fn chunk ->
      :ok =
        :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])

      receive do
      after
        150 -> :ok
      end
    end)

    :gen_tcp.send(socket, "0\r\n\r\n")
  end

  defp send_response(socket, status, body, :normal) do
    reason = if status in 200..299, do: "OK", else: "Error"

    header =
      "HTTP/1.1 #{status} #{reason}\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n"

    :gen_tcp.send(socket, [header, body])
  end

  defp chunks(<<>>, _size), do: []
  defp chunks(body, size) when byte_size(body) <= size, do: [body]

  defp chunks(body, size) do
    <<chunk::binary-size(^size), rest::binary>> = body
    [chunk | chunks(rest, size)]
  end
end
