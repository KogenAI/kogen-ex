defmodule Kogen.Harness.ExchangeTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Contracts.Project
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request
  alias Kogen.Harness.Opts
  alias Kogen.Provider.ChatGPT

  @server_wait_ms 20_000

  test "an idle streamed model request retries exactly once and records the retry", %{
    tmp_dir: tmp_dir
  } do
    item = %{
      "id" => "msg_retry",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "ok"}]
    }

    response = %{
      "id" => "resp_retry",
      "status" => "completed",
      "output" => [item],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    body =
      "event: response.completed\r\ndata: " <>
        encode(%{"type" => "response.completed", "response" => response}) <> "\r\n\r\n"

    {url, server} = start_idle_then_reply(body)
    test_process = self()
    workdir = Path.join(tmp_dir, "project")
    run_dir = Path.join(tmp_dir, "run")
    File.mkdir_p!(workdir)

    opts = %Opts{
      workdir: workdir,
      run_dir: run_dir,
      project: project(workdir),
      provider_mod: ChatGPT,
      provider_config: %ChatGPT.Config{
        access_token: "test-token",
        account_id: "test-account",
        endpoint: url,
        timeout_ms: 400
      },
      proc_mod: Kogen.Proc,
      event_recorder: fn event ->
        send(test_process, {:recorded_event, event})
        :ok
      end
    }

    assert {:ok, result} =
             Exchange.respond(opts, %Request{
               stage: :shape,
               turn: 1,
               model: "gpt-6-luna",
               effort: "low",
               instructions: "Shape the Intent.",
               items: [%{"role" => "user", "content" => []}],
               tool_names: [],
               remaining_ms: 60_000
             })

    assert result.text == "ok"
    assert_receive {:http_request, :first, _bytes, first_at}
    assert_receive {:http_request, :retry, _bytes, retry_at}
    assert retry_at - first_at >= 560
    assert_receive {:recorded_event, %{event: :provider_retry, stage: :shape, attempt: 1}}

    events =
      run_dir
      |> Path.join("transcript.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)

    assert Enum.count(events, &(Map.get(&1, "event") == "provider_retry")) == 1
    assert Enum.count(events, &(Map.get(&1, "event") == "request")) == 2
    send(server, :stop)
  end

  defp project(root) do
    %Project{
      root: root,
      name: "exchange-test",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{}
    }
  end

  defp start_idle_then_reply(body) do
    {:ok, listener, url} = listen()
    parent = self()

    server =
      spawn_link(fn ->
        {:ok, first_socket} = :gen_tcp.accept(listener)
        first_request = receive_request(first_socket, <<>>)
        send(parent, {:http_request, :first, first_request, System.monotonic_time(:millisecond)})

        # Leave the first response idle while accepting Kogen's backoff-delayed retry.
        {:ok, retry_socket} = :gen_tcp.accept(listener, @server_wait_ms)
        retry_request = receive_request(retry_socket, <<>>)
        send(parent, {:http_request, :retry, retry_request, System.monotonic_time(:millisecond)})
        send_chunked(retry_socket, body)
        :gen_tcp.close(first_socket)
        :gen_tcp.close(retry_socket)
        :gen_tcp.close(listener)

        receive do
          :stop -> :ok
        after
          @server_wait_ms -> :ok
        end
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
      case :gen_tcp.recv(socket, 0, @server_wait_ms) do
        {:ok, chunk} -> receive_request(socket, buffer <> chunk)
        {:error, reason} -> raise "test HTTP server failed to read request: #{inspect(reason)}"
      end
    end
  end

  defp request_complete?(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [headers, body] -> byte_size(body) >= content_length(headers)
      _partial -> false
    end
  end

  defp content_length(headers) do
    headers
    |> :binary.split("\r\n", [:global])
    |> Enum.find_value(0, fn line ->
      case :binary.split(String.downcase(line), ":", [:global]) do
        ["content-length", value] -> String.to_integer(String.trim(value))
        _other -> nil
      end
    end)
  end

  defp send_chunked(socket, body) do
    header =
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"

    :ok = :gen_tcp.send(socket, header)

    :ok =
      :gen_tcp.send(socket, [
        Integer.to_string(byte_size(body), 16),
        "\r\n",
        body,
        "\r\n0\r\n\r\n"
      ])
  end

  defp encode(value), do: value |> :json.encode() |> IO.iodata_to_binary()
end
