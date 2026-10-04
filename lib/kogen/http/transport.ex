defmodule Kogen.Http.Transport do
  @moduledoc false

  alias Kogen.Http.Transport.Proxy

  defmodule Response do
    @moduledoc false
    @enforce_keys [:status, :body, :chunks]
    defstruct @enforce_keys

    @type t :: %__MODULE__{status: pos_integer(), body: binary(), chunks: [binary()]}
  end

  defmodule State do
    @moduledoc false
    defstruct status: nil, chunks: [], size: 0
  end

  @max_response_bytes 16_000_000

  @spec post_form(String.t(), [{String.t(), String.t()}], pos_integer(), keyword()) ::
          {:ok, pos_integer(), binary()}
          | {:error, :timeout | :transport | :invalid_proxy | :proxy_auth_unsupported}
  def post_form(url, fields, timeout_ms, opts \\ [])
      when is_binary(url) and is_list(fields) and is_integer(timeout_ms) and is_list(opts) do
    body = URI.encode_query(fields)
    request = {String.to_charlist(url), [], ~c"application/x-www-form-urlencoded", body}
    request_small(:post, request, url, timeout_ms, opts)
  end

  @spec get(String.t(), pos_integer(), keyword()) ::
          {:ok, pos_integer(), binary()}
          | {:error, :timeout | :transport | :invalid_proxy | :proxy_auth_unsupported}
  def get(url, timeout_ms, opts \\ [])
      when is_binary(url) and is_integer(timeout_ms) and is_list(opts) do
    request_small(:get, {String.to_charlist(url), []}, url, timeout_ms, opts)
  end

  @spec post_stream(String.t(), [{String.t(), String.t()}], binary(), pos_integer(), keyword()) ::
          {:ok, Response.t()}
          | {:error,
             :timeout | :transport | :too_large | :invalid_proxy | :proxy_auth_unsupported}
  def post_stream(url, headers, body, timeout_ms, opts \\ [])
      when is_binary(url) and is_list(headers) and is_binary(body) and is_integer(timeout_ms) and
             is_list(opts) do
    with {:ok, _apps} <- Application.ensure_all_started(:inets),
         {:ok, _apps} <- Application.ensure_all_started(:ssl) do
      Proxy.with_profile(url, Keyword.get(opts, :proxy_env, %{}), fn profile ->
        request(profile, url, headers, body, timeout_ms, opts)
      end)
    else
      {:error, _reason} -> {:error, :transport}
    end
  end

  defp request(profile, url, headers, body, timeout_ms, opts) do
    request = {String.to_charlist(url), charlist_headers(headers), ~c"application/json", body}

    case httpc_request(profile, :post, request, http_options(url, opts),
           sync: false,
           stream: :self,
           full_result: true
         ) do
      {:ok, ref} ->
        receive_response(
          ref,
          System.monotonic_time(:millisecond) + timeout_ms,
          %State{},
          profile
        )

      {:error, _reason} ->
        {:error, :transport}
    end
  end

  defp request_small(method, request, url, timeout_ms, opts) do
    with {:ok, _apps} <- Application.ensure_all_started(:inets),
         {:ok, _apps} <- Application.ensure_all_started(:ssl) do
      Proxy.with_profile(url, Keyword.get(opts, :proxy_env, %{}), fn profile ->
        case httpc_request(profile, method, request, small_http_options(url, timeout_ms, opts),
               body_format: :binary
             ) do
          {:ok, {{_version, status, _reason}, _headers, body}} -> {:ok, status, body}
          {:error, reason} -> {:error, transport_reason(reason)}
        end
      end)
    else
      {:error, _reason} -> {:error, :transport}
    end
  end

  defp httpc_request(nil, method, request, http_options, request_options),
    do: :httpc.request(method, request, http_options, request_options)

  defp httpc_request(profile, method, request, http_options, request_options),
    do: :httpc.request(method, request, http_options, request_options, profile)

  defp small_http_options(url, timeout_ms, opts) do
    [
      timeout: timeout_ms,
      connect_timeout: min(timeout_ms, 30_000),
      autoredirect: false,
      autoretry: 0,
      ssl: ssl_options(url, opts)
    ]
  end

  defp transport_reason(reason) do
    if timeout_reason?(reason), do: :timeout, else: :transport
  end

  defp charlist_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp http_options(url, opts) do
    [
      timeout: :infinity,
      connect_timeout: 30_000,
      autoredirect: false,
      autoretry: 0,
      ssl: ssl_options(url, opts)
    ]
  end

  defp ssl_options(url, opts) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        [
          verify: :verify_peer,
          cacerts: Keyword.get(opts, :cacerts, :public_key.cacerts_get()),
          depth: 4,
          server_name_indication: String.to_charlist(host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]

      _ ->
        []
    end
  end

  defp receive_response(ref, deadline, %State{} = state, profile) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      cancel(ref, profile)
      {:error, :timeout}
    else
      receive do
        {:http, {^ref, :stream_start, _headers}} ->
          receive_response(ref, deadline, %{state | status: 200}, profile)

        {:http, {^ref, :stream_start, _headers, _handler}} ->
          receive_response(ref, deadline, %{state | status: 200}, profile)

        {:http, {^ref, :stream, chunk}} when is_binary(chunk) ->
          append_chunk(ref, deadline, state, chunk, profile)

        {:http, {^ref, :stream_end, _headers}} ->
          finish_stream(state)

        {:http, {^ref, {{_version, status, _reason}, _headers, body}}} ->
          full_response(status, body)

        {:http, {^ref, {:error, reason}}} ->
          transport_error(reason)
      after
        remaining ->
          cancel(ref, profile)
          {:error, :timeout}
      end
    end
  end

  defp append_chunk(ref, deadline, state, chunk, profile) do
    size = state.size + byte_size(chunk)

    if size > @max_response_bytes do
      cancel(ref, profile)
      {:error, :too_large}
    else
      receive_response(
        ref,
        deadline,
        %{state | chunks: [chunk | state.chunks], size: size},
        profile
      )
    end
  end

  defp finish_stream(state) do
    chunks = Enum.reverse(state.chunks)

    {:ok,
     %Response{status: state.status || 200, body: IO.iodata_to_binary(chunks), chunks: chunks}}
  end

  defp full_response(status, body)
       when is_binary(body) and byte_size(body) <= @max_response_bytes do
    {:ok, %Response{status: status, body: body, chunks: [body]}}
  end

  defp full_response(_status, _body), do: {:error, :too_large}

  defp transport_error(reason) do
    if timeout_reason?(reason), do: {:error, :timeout}, else: {:error, :transport}
  end

  defp timeout_reason?(:timeout), do: true
  defp timeout_reason?(:connect_timeout), do: true

  defp timeout_reason?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&timeout_reason?/1)

  defp timeout_reason?(list) when is_list(list), do: Enum.any?(list, &timeout_reason?/1)
  defp timeout_reason?(_reason), do: false

  defp cancel(ref, nil), do: :httpc.cancel_request(ref)

  defp cancel(ref, profile) do
    :httpc.cancel_request(ref, profile)
    :ok
  end
end
