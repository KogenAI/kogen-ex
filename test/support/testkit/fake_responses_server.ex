defmodule Kogen.Testkit.FakeResponsesServer do
  @moduledoc """
  A scripted loopback Responses endpoint. Each accepted connection consumes the next behaviour
  (the last one repeats) and the owner receives `{:fake_request, index, request_body, monotonic_ms}` with the decoded JSON body.

  Behaviours: `{:ok, text}`, `{:status, code, body}`, `:hang` (no reply), `:close` (drop the
  connection), `:trickle` (a 200 stream that emits a keepalive comment every 50 ms and never
  completes), `:stall` (a 200 stream that sends one event and then nothing),
  `{:events, text, chunks, ms}` (raw body chunks `ms` apart, then the completed response) and
  `{:steady, text, events, ms}` (`events` progress events `ms` apart, then the completed response).
  """

  @read_ms 20_000

  @type behaviour ::
          {:ok, String.t()}
          | {:status, pos_integer(), binary()}
          | {:cut, [map()], :close | :hang | :end}
          | :hang
          | :close
          | :trickle
          | :stall
          | {:events, String.t(), [binary()], pos_integer()}
          | {:steady, String.t(), pos_integer(), pos_integer()}

  @spec start([behaviour()]) :: {String.t(), pid()}
  def start([_first | _rest] = script) do
    owner = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    server = spawn_link(fn -> accept(listener, owner, script, 1) end)
    {"http://127.0.0.1:#{port}/responses", server}
  end

  @spec stop(pid()) :: :ok
  def stop(server) do
    Process.unlink(server)
    Process.exit(server, :kill)
    :ok
  end

  defp accept(listener, owner, script, index) do
    {:ok, socket} = :gen_tcp.accept(listener)
    {behaviour, rest} = next(script)
    spawn(fn -> serve(socket, owner, index, behaviour) end)
    accept(listener, owner, rest, index + 1)
  end

  defp next([last]), do: {last, [last]}
  defp next([head | rest]), do: {head, rest}

  defp serve(socket, owner, index, behaviour) do
    request = read_request(socket, <<>>)
    [_headers, body] = :binary.split(request, "\r\n\r\n")
    send(owner, {:fake_request, index, :json.decode(body), System.monotonic_time(:millisecond)})
    respond(socket, behaviour)
    send(owner, {:fake_request_ended, index})
  end

  defp respond(socket, {:ok, text}), do: send_stream(socket, text)

  defp respond(socket, {:cut, events, ending}) do
    :ok = :gen_tcp.send(socket, stream_header())
    pause(20)

    for event <- events do
      data = "data: " <> IO.iodata_to_binary(:json.encode(event)) <> "\n\n"
      :ok = :gen_tcp.send(socket, chunk(data))
      pause(20)
    end

    case ending do
      :end -> :gen_tcp.send(socket, "0\r\n\r\n")
      other -> respond(socket, other)
    end
  end

  defp respond(socket, :stall) do
    started_stream(socket)
    respond(socket, :hang)
  end

  defp respond(socket, {:events, text, chunks, interval_ms}) do
    :ok = :gen_tcp.send(socket, stream_header())
    pause(20)

    for bytes <- chunks do
      :ok = :gen_tcp.send(socket, chunk(bytes))
      pause(interval_ms)
    end

    send_completed(socket, text)
  end

  defp respond(socket, {:steady, text, events, interval_ms}) do
    :ok = :gen_tcp.send(socket, stream_header())

    for _event <- 1..events do
      :ok = :gen_tcp.send(socket, chunk(progress_event()))
      pause(interval_ms)
    end

    send_completed(socket, text)
  end

  defp respond(socket, {:status, code, body}) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{code} Test\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
        body
    )

    :gen_tcp.close(socket)
  end

  defp respond(socket, :close), do: :gen_tcp.close(socket)

  defp respond(socket, :hang) do
    _closed = :gen_tcp.recv(socket, 0, @read_ms)
    :gen_tcp.close(socket)
  end

  defp respond(socket, :trickle) do
    :ok = :gen_tcp.send(socket, stream_header())
    trickle(socket, 0)
  end

  defp trickle(socket, count) when count < 400 do
    case :gen_tcp.send(socket, "1\r\n:\r\n") do
      :ok ->
        receive do
        after
          50 -> trickle(socket, count + 1)
        end

      {:error, _closed} ->
        :ok
    end
  end

  defp trickle(socket, _count), do: :gen_tcp.close(socket)

  defp send_stream(socket, text) do
    :ok = :gen_tcp.send(socket, stream_header())
    send_completed(socket, text)
  end

  defp send_completed(socket, text) do
    item = %{
      "id" => "msg_fake",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }

    response = %{
      "id" => "resp_fake",
      "status" => "completed",
      "output" => [item],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    event =
      "event: response.completed\r\ndata: " <>
        IO.iodata_to_binary(
          :json.encode(%{"type" => "response.completed", "response" => response})
        ) <>
        "\r\n\r\n"

    :ok = :gen_tcp.send(socket, [chunk(event), "0\r\n\r\n"])
    :gen_tcp.close(socket)
  end

  # httpc holds body bytes that arrive in the header's packet until more data comes, so the
  # first event goes out on its own.
  defp started_stream(socket) do
    :ok = :gen_tcp.send(socket, stream_header())
    pause(20)
    :ok = :gen_tcp.send(socket, chunk(progress_event()))
  end

  defp pause(ms) do
    receive do
    after
      ms -> :ok
    end
  end

  defp chunk(data), do: [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"]

  defp progress_event do
    "event: response.output_item.done\r\ndata: " <>
      ~s({"type":"response.output_item.done","item":{"type":"reasoning","summary":[]}}) <>
      "\r\n\r\n"
  end

  defp stream_header do
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
  end

  defp read_request(socket, buffer) do
    if complete?(buffer) do
      buffer
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, @read_ms)
      read_request(socket, buffer <> chunk)
    end
  end

  defp complete?(buffer) do
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
end
