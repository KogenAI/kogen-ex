defmodule Kogen.Grok do
  @moduledoc "Streams xAI Responses requests with Kogen's Grok subscription login."
  @behaviour Kogen.Contracts.ProviderPort

  use Boundary,
    deps: [Kogen.Contracts, Kogen.Http, Kogen.Proc, Kogen.Provider],
    exports: [Config, CredentialStore, CredentialStore.Profile, DeviceAuth]

  import Bitwise

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Grok.Codec
  alias Kogen.Grok.CredentialStore
  alias Kogen.Grok.Refresh
  alias Kogen.Http.Transport

  @responses_endpoint "https://cli-chat-proxy.grok.com/v1/responses"
  @request_timeout_ms 300_000

  defmodule Config do
    @moduledoc false
    @derive {Inspect, except: [:proxy_env, :token_endpoint]}
    @enforce_keys [:source, :label, :endpoint, :timeout_ms]
    defstruct source: :kogen_owned,
              label: nil,
              endpoint: nil,
              timeout_ms: nil,
              first_byte_timeout_ms: 120_000,
              total_timeout_ms: 1_200_000,
              credential_root: nil,
              backend: nil,
              token_endpoint: nil,
              proxy_env: %{}

    @type t :: %__MODULE__{
            source: :kogen_owned,
            label: String.t(),
            endpoint: String.t(),
            timeout_ms: pos_integer(),
            first_byte_timeout_ms: pos_integer(),
            total_timeout_ms: pos_integer(),
            credential_root: Path.t() | nil,
            backend: :file | :keychain | nil,
            token_endpoint: String.t() | nil,
            proxy_env: %{String.t() => String.t()}
          }
  end

  @spec owned_config(Path.t(), :file | :keychain, String.t(), keyword()) ::
          {:ok, Config.t()} | {:error, ProviderError.t()}
  def owned_config(root, backend, label, opts \\ []) when backend in [:file, :keychain] do
    case CredentialStore.load(root, backend, label, opts) do
      {:ok, _credentials} ->
        {:ok,
         %Config{
           source: :kogen_owned,
           label: label,
           endpoint: Keyword.get(opts, :endpoint, @responses_endpoint),
           timeout_ms: @request_timeout_ms,
           credential_root: root,
           backend: backend,
           token_endpoint: Keyword.get(opts, :token_endpoint),
           proxy_env: Keyword.get(opts, :proxy_env, %{})
         }}

      {:error, _reason} ->
        login_error("Grok login is missing or invalid; run `kogen provider login grok`.")
    end
  end

  @impl true
  @spec respond(term(), ModelRequest.t()) ::
          {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
  def respond(%Config{} = config, %ModelRequest{} = request) do
    if valid_config?(config) do
      respond_with_refresh(config, request)
    else
      provider_error(:malformed, "Grok provider configuration is invalid.")
    end
  end

  def respond(_config, _request),
    do: provider_error(:malformed, "Grok provider configuration or request is invalid.")

  defp respond_with_refresh(config, request) do
    with {:ok, credentials} <- credential_for_request(config) do
      case execute(config, request, credentials.access_token) do
        {:ok, response} ->
          {:ok, response}

        {:error, %ProviderError{class: :login}} ->
          with {:ok, refreshed} <-
                 Refresh.force(
                   config.credential_root,
                   config.backend,
                   config.label,
                   credentials.access_token,
                   refresh_opts(config)
                 ),
               {:ok, response} <- execute(config, request, refreshed.access_token) do
            {:ok, response}
          else
            {:error, reason} -> refresh_error(reason)
          end

        error ->
          error
      end
    end
  end

  defp credential_for_request(config) do
    case Refresh.access_token(
           config.credential_root,
           config.backend,
           config.label,
           refresh_opts(config)
         ) do
      {:ok, credentials} -> {:ok, credentials}
      {:error, reason} -> refresh_error(reason)
    end
  end

  defp refresh_opts(config) do
    opts = [proxy_env: config.proxy_env]

    if is_binary(config.token_endpoint),
      do: Keyword.put(opts, :token_endpoint, config.token_endpoint),
      else: opts
  end

  defp execute(config, request, token) do
    with {:ok, body} <- Codec.encode_request(request),
         {:ok, response} <-
           Transport.post_stream(
             config.endpoint,
             headers(request, token),
             body,
             config.timeout_ms,
             proxy_env: config.proxy_env,
             first_byte_ms: config.first_byte_timeout_ms,
             total_ms: config.total_timeout_ms,
             on_chunk: progress(request.on_progress)
           ) do
      handle_response(response)
    else
      {:error, reason} when reason in [:timeout, :transport, :too_large] ->
        transport_error(reason)

      {:error, reason} when reason in [:invalid_proxy, :proxy_auth_unsupported] ->
        transport_error(reason)

      {:error, %ProviderError{} = error} ->
        {:error, error}
    end
  end

  defp headers(request, token) do
    version = :kogen |> Application.spec(:vsn) |> List.to_string()

    [
      {"authorization", "Bearer " <> token},
      {"x-xai-token-auth", "xai-grok-cli"},
      {"x-authenticateresponse", "authenticate-response"},
      {"x-grok-model-override", request.model},
      {"x-grok-client-identifier", "kogen"},
      {"x-grok-client-mode", "headless"},
      {"x-grok-client-version", version},
      {"user-agent", "kogen/" <> version},
      {"accept", "text/event-stream"},
      {"x-grok-req-id", request_id()}
    ] ++ cache_headers(request.prompt_cache_key)
  end

  defp cache_headers(key) when is_binary(key) and key != "" do
    [{"x-grok-conv-id", key}, {"x-grok-session-id", key}]
  end

  defp cache_headers(_key), do: []

  defp request_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    Enum.map_join([{a, 8}, {b, 4}, {c, 4}, {d, 4}, {e, 12}], "-", fn {part, width} ->
      part |> Integer.to_string(16) |> String.pad_leading(width, "0")
    end)
  end

  defp progress(callback) when is_function(callback, 0) do
    fn chunk -> if byte_size(chunk) > 0, do: callback.(), else: :ok end
  end

  defp progress(_callback), do: nil

  defp handle_response(%Transport.Response{status: status, chunks: chunks})
       when status in 200..299 do
    stream = Enum.reduce(chunks, Codec.new_stream(), &Codec.feed(&2, &1))
    Codec.finish(stream)
  end

  defp handle_response(%Transport.Response{status: status, body: body}),
    do: response_error(status, body)

  defp valid_config?(%Config{} = config) do
    is_binary(config.credential_root) and config.backend in [:file, :keychain] and
      is_binary(config.label) and config.label != "" and is_binary(config.endpoint) and
      Enum.all?(
        [config.timeout_ms, config.first_byte_timeout_ms, config.total_timeout_ms],
        &(is_integer(&1) and &1 > 0)
      )
  end

  defp response_error(401, _body),
    do: provider_error(:login, "Grok rejected this session; run `kogen provider login grok`.")

  defp response_error(403, _body),
    do: provider_error(:login, "This Grok account cannot access the requested model.")

  defp response_error(status, body) do
    cond do
      status == 429 or usage_limit_body?(body) ->
        provider_error(:usage_limit, "Grok subscription usage limit reached.")

      status in 500..599 or overloaded_body?(body) ->
        provider_error(:overload, "Grok service is temporarily overloaded.")

      status in 200..299 ->
        provider_error(:malformed, "Grok returned a malformed response stream.")

      true ->
        provider_error(:malformed, "Grok rejected the request (HTTP #{status}).")
    end
  end

  defp usage_limit_body?(body) do
    body = normalized_error_body(body)

    Enum.any?(
      ["usage_limit", "usage limit", "quota exceeded", "rate limit"],
      &String.contains?(body, &1)
    )
  end

  defp overloaded_body?(body) do
    body = normalized_error_body(body)
    Enum.any?(["server_is_overloaded", "overloaded", "overload"], &String.contains?(body, &1))
  end

  defp normalized_error_body(body),
    do: if(String.valid?(body), do: String.downcase(body), else: "")

  defp refresh_error(reason) when reason in [:invalid_proxy, :proxy_auth_unsupported],
    do: transport_error(reason)

  defp refresh_error(reason) do
    message =
      case reason do
        :refresh_timeout ->
          "Grok session refresh timed out."

        :refresh_transport ->
          "Grok session could not refresh. Check the network and sign in again."

        _other ->
          "Grok login is unavailable; run `kogen provider login grok`."
      end

    provider_error(:login, message)
  end

  defp transport_error(:timeout), do: provider_error(:timeout, "Grok request timed out.")

  defp transport_error(:too_large),
    do: provider_error(:malformed, "Grok response exceeded the size limit.")

  defp transport_error(:transport),
    do: provider_error(:transport, "Grok request could not connect.")

  defp transport_error(:proxy_auth_unsupported),
    do:
      provider_error(
        :transport,
        "HTTPS proxy URLs with credentials are not supported; configure a proxy URL without credentials."
      )

  defp transport_error(:invalid_proxy),
    do:
      provider_error(
        :transport,
        "HTTPS proxy configuration is invalid; use an http://host:port URL without credentials."
      )

  defp provider_error(class, message),
    do: {:error, %ProviderError{class: class, message: message}}

  defp login_error(message), do: provider_error(:login, message)
end
