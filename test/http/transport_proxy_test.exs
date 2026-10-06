defmodule Kogen.Http.TransportProxyTest do
  use ExUnit.Case, async: true

  alias Kogen.Http.Transport

  test "HTTPS CONNECT tunnels TLS for the requested hostname and serves the request" do
    {tls_port, tls_server, tls_listener} = start_tls_server("proxied")
    {proxy_url, proxy_server, proxy_listener} = start_connect_proxy(tls_port, :proxied)

    try do
      assert {:ok, %Transport.Response{status: 200, body: "proxied"}} =
               Transport.post_stream("https://chatgpt.com/responses", [], "{}", 15_000,
                 proxy_env: %{"https_proxy" => proxy_url},
                 cacerts: test_cacerts()
               )

      assert_receive {:proxy_connect, :proxied, "CONNECT chatgpt.com:443 HTTP/1.1"}
      assert_receive {:tls_request, request}
      assert request =~ "POST /responses HTTP/1.1"
    after
      stop_connect_proxy(proxy_server, proxy_listener)
      stop_tls_server(tls_server, tls_listener)
    end
  end

  test "NO_PROXY host, dotted suffix, and wildcard bypass the CONNECT proxy" do
    {tls_port, tls_server, tls_listener} = start_tls_server("direct", 3)
    {proxy_url, proxy_server, proxy_listener} = start_connect_proxy(tls_port, :bypass)

    try do
      Enum.each([{"no_proxy", "localhost"}, {"NO_PROXY", ".LOCALHOST"}, {"no_proxy", " * "}], fn
        {name, no_proxy} ->
          assert {:ok, 200, "direct"} =
                   Transport.get("https://localhost:#{tls_port}/", 15_000,
                     proxy_env: %{"HTTPS_PROXY" => proxy_url, name => no_proxy},
                     cacerts: test_cacerts()
                   )
      end)

      refute_receive {:proxy_connect, :bypass, _line}, 100
    after
      stop_connect_proxy(proxy_server, proxy_listener)
      stop_tls_server(tls_server, tls_listener)
    end
  end

  test "HTTPS proxy variables follow lowercase, uppercase, and fallback order" do
    {tls_port, tls_server, tls_listener} = start_tls_server("ordered", 6)

    {https_lower, https_lower_server, https_lower_listener} =
      start_connect_proxy(tls_port, :https_lower)

    {https_upper, https_upper_server, https_upper_listener} =
      start_connect_proxy(tls_port, :https_upper)

    {all_lower, all_lower_server, all_lower_listener} = start_connect_proxy(tls_port, :all_lower)
    {all_upper, all_upper_server, all_upper_listener} = start_connect_proxy(tls_port, :all_upper)

    {http_lower, http_lower_server, http_lower_listener} =
      start_connect_proxy(tls_port, :http_lower)

    {http_upper, http_upper_server, http_upper_listener} =
      start_connect_proxy(tls_port, :http_upper)

    proxy_env = %{
      "https_proxy" => https_lower,
      "HTTPS_PROXY" => https_upper,
      "all_proxy" => all_lower,
      "ALL_PROXY" => all_upper,
      "http_proxy" => http_lower,
      "HTTP_PROXY" => http_upper
    }

    try do
      assert {:ok, 200, "ordered"} =
               Transport.get("https://chatgpt.com/", 15_000, proxy_opts(proxy_env))

      assert_receive {:proxy_connect, :https_lower, "CONNECT chatgpt.com:443 HTTP/1.1"}

      proxy_env = Map.delete(proxy_env, "https_proxy")

      assert {:ok, 200, "ordered"} =
               Transport.get("https://chatgpt.com/", 15_000, proxy_opts(proxy_env))

      assert_receive {:proxy_connect, :https_upper, "CONNECT chatgpt.com:443 HTTP/1.1"}

      proxy_env = Map.delete(proxy_env, "HTTPS_PROXY")

      assert {:ok, 200, "ordered"} =
               Transport.get("https://chatgpt.com/", 15_000, proxy_opts(proxy_env))

      assert_receive {:proxy_connect, :all_lower, "CONNECT chatgpt.com:443 HTTP/1.1"}

      proxy_env = Map.delete(proxy_env, "all_proxy")

      assert {:ok, 200, "ordered"} =
               Transport.get("https://chatgpt.com/", 15_000, proxy_opts(proxy_env))

      assert_receive {:proxy_connect, :all_upper, "CONNECT chatgpt.com:443 HTTP/1.1"}

      proxy_env = Map.delete(proxy_env, "ALL_PROXY")

      assert {:ok, 200, "ordered"} =
               Transport.get("https://chatgpt.com/", 15_000, proxy_opts(proxy_env))

      assert_receive {:proxy_connect, :http_lower, "CONNECT chatgpt.com:443 HTTP/1.1"}

      proxy_env = Map.delete(proxy_env, "http_proxy")

      assert {:ok, 200, "ordered"} =
               Transport.get("https://chatgpt.com/", 15_000, proxy_opts(proxy_env))

      assert_receive {:proxy_connect, :http_upper, "CONNECT chatgpt.com:443 HTTP/1.1"}
    after
      stop_connect_proxy(https_lower_server, https_lower_listener)
      stop_connect_proxy(https_upper_server, https_upper_listener)
      stop_connect_proxy(all_lower_server, all_lower_listener)
      stop_connect_proxy(all_upper_server, all_upper_listener)
      stop_connect_proxy(http_lower_server, http_lower_listener)
      stop_connect_proxy(http_upper_server, http_upper_listener)
      stop_tls_server(tls_server, tls_listener)
    end
  end

  defp proxy_opts(proxy_env), do: [proxy_env: proxy_env, cacerts: test_cacerts()]

  defp test_cacerts do
    path = Path.join(__DIR__, "fixtures/tls/chatgpt-test-ca.pem")
    {:ok, pem} = File.read(path)
    for {:Certificate, der, _enc} <- :public_key.pem_decode(pem), do: der
  end

  defp start_tls_server(body, accepts \\ 1) do
    certfile = Path.join(__DIR__, "fixtures/tls/chatgpt-test-cert.pem")
    keyfile = Path.join(__DIR__, "fixtures/tls/chatgpt-test-key.pem")

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        certfile: String.to_charlist(certfile),
        keyfile: String.to_charlist(keyfile)
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :ssl.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        for _attempt <- 1..accepts do
          case :ssl.transport_accept(listener, 15_000) do
            {:ok, transport_socket} ->
              {:ok, socket} = :ssl.handshake(transport_socket, [], 15_000)
              request = receive_ssl_request(socket, <<>>)
              send(parent, {:tls_request, request})
              :ok = :ssl.send(socket, https_response(body))
              :ok = :ssl.close(socket)

            {:error, :closed} ->
              :ok
          end
        end
      end)

    {port, server, listener}
  end

  defp receive_ssl_request(socket, buffer) do
    if request_complete?(buffer) do
      buffer
    else
      {:ok, chunk} = :ssl.recv(socket, 0, 15_000)
      receive_ssl_request(socket, buffer <> chunk)
    end
  end

  defp request_complete?(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [headers, body] -> byte_size(body) >= content_length(headers)
      _other -> false
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

  defp https_response(body) do
    [
      "HTTP/1.1 200 OK\r\nContent-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\nConnection: close\r\n\r\n",
      body
    ]
  end

  defp start_connect_proxy(upstream_port, tag) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    parent = self()

    proxy =
      spawn(fn ->
        case :gen_tcp.accept(listener) do
          {:ok, client} ->
            connect_request = receive_headers(client, <<>>)
            [connect_line | _rest] = String.split(connect_request, "\r\n")
            send(parent, {:proxy_connect, tag, connect_line})

            {:ok, upstream} =
              :gen_tcp.connect({127, 0, 0, 1}, upstream_port, [:binary, active: false])

            :ok = :gen_tcp.send(client, "HTTP/1.1 200 Connection established\r\n\r\n")
            relay_proxy_sockets(client, upstream)

          {:error, :closed} ->
            :ok
        end
      end)

    {"http://127.0.0.1:#{port}", proxy, listener}
  end

  defp receive_headers(socket, buffer) do
    if :binary.match(buffer, "\r\n\r\n") == :nomatch do
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 15_000)
      receive_headers(socket, buffer <> chunk)
    else
      buffer
    end
  end

  defp relay_proxy_sockets(client, upstream) do
    :inet.setopts(client, active: true)
    :inet.setopts(upstream, active: true)
    relay_proxy_loop(client, upstream)
  end

  defp relay_proxy_loop(client, upstream) do
    receive do
      {:tcp, ^client, bytes} ->
        :ok = :gen_tcp.send(upstream, bytes)
        relay_proxy_loop(client, upstream)

      {:tcp, ^upstream, bytes} ->
        :ok = :gen_tcp.send(client, bytes)
        relay_proxy_loop(client, upstream)

      {:tcp_closed, ^client} ->
        :gen_tcp.close(upstream)

      {:tcp_closed, ^upstream} ->
        :gen_tcp.close(client)
    end
  end

  defp stop_connect_proxy(proxy, listener),
    do: stop_process(proxy, fn -> :gen_tcp.close(listener) end)

  defp stop_tls_server(server, listener), do: stop_process(server, fn -> :ssl.close(listener) end)

  defp stop_process(process, close_listener) do
    monitor = Process.monitor(process)
    close_listener.()
    if Process.alive?(process), do: Process.exit(process, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^process, _reason} -> :ok
    after
      1_000 -> :ok
    end
  end
end
