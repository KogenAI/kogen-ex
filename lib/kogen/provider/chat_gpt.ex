defmodule Kogen.Provider.ChatGPT do
  @moduledoc "Streams Responses requests using Kogen's ChatGPT login."
  @behaviour Kogen.Contracts.ProviderPort

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Http.Transport
  alias Kogen.Provider.ChatGPT.Auth
  alias Kogen.Provider.ChatGPT.Codec
  alias Kogen.Provider.ChatGPT.CredentialStore
  alias Kogen.Provider.ChatGPT.Refresh

  @responses_endpoint "https://api.openai.com/v1/responses"
  @benchmark_endpoint "https://chatgpt.com/backend-api/codex/responses"
  @request_timeout_ms 300_000
  @manage_usage "https://chatgpt.com/settings/usage"

  defmodule Config do
    @moduledoc false
    @derive {Inspect, except: [:access_token, :account_id, :proxy_env]}
    @enforce_keys [:endpoint, :timeout_ms]
    defstruct source: :custom,
              label: "custom",
              endpoint: nil,
              timeout_ms: nil,
              first_byte_timeout_ms: 120_000,
              total_timeout_ms: 600_000,
              credential_path: nil,
              credential_root: nil,
              backend: nil,
              access_token: nil,
              account_id: nil,
              proxy_env: %{}

    @type t :: %__MODULE__{
            source: :kogen_owned | :custom,
            label: String.t(),
            endpoint: String.t(),
            timeout_ms: pos_integer(),
            first_byte_timeout_ms: pos_integer(),
            total_timeout_ms: pos_integer(),
            credential_path: Path.t() | nil,
            credential_root: Path.t() | nil,
            backend: :file | :keychain | nil,
            access_token: String.t() | nil,
            account_id: String.t() | nil,
            proxy_env: %{String.t() => String.t()}
          }
  end

  @spec config(Path.t()) :: {:ok, Config.t()} | {:error, ProviderError.t()}
  def config(auth_path) when is_binary(auth_path) do
    with {:ok, credentials} <- Auth.load(auth_path) do
      {:ok,
       %Config{
         source: :custom,
         label: "custom",
         endpoint: @benchmark_endpoint,
         timeout_ms: @request_timeout_ms,
         credential_path: auth_path,
         access_token: credentials.access_token,
         account_id: credentials.account_id
       }}
    end
  end

  @spec config(term()) :: {:error, ProviderError.t()}
  def config(_auth_path), do: login_error("ChatGPT login path is invalid.")

  @spec owned_config(Path.t(), :file | :keychain, String.t()) ::
          {:ok, Config.t()} | {:error, ProviderError.t()}
  def owned_config(root, backend, label) do
    case CredentialStore.load(root, backend, label) do
      {:ok, _credentials} ->
        {:ok,
         %Config{
           source: :kogen_owned,
           label: label,
           endpoint: @responses_endpoint,
           timeout_ms: @request_timeout_ms,
           credential_root: root,
           backend: backend
         }}

      {:error, _reason} ->
        login_error("ChatGPT login is missing or invalid; run `kogen provider login chatgpt`.")
    end
  end

  @impl true
  @spec respond(term(), ModelRequest.t()) ::
          {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
  def respond(%Config{} = config, %ModelRequest{} = request) do
    if valid_config?(config) do
      respond_with_refresh(config, request)
    else
      provider_error(:malformed, "ChatGPT provider configuration is invalid.")
    end
  end

  def respond(_config, _request),
    do: provider_error(:malformed, "ChatGPT provider configuration or request is invalid.")

  @doc false
  @spec respond_with_transcript(Config.t(), ModelRequest.t()) ::
          {:ok, ModelResponse.t(), binary()} | {:error, ProviderError.t()}
  def respond_with_transcript(%Config{} = config, %ModelRequest{} = request) do
    with {:ok, token, account_id} <- credential_for_request(config) do
      execute(config, request, token, account_id)
    end
  end

  defp respond_with_refresh(config, request) do
    with {:ok, token, account_id} <- credential_for_request(config) do
      case execute(config, request, token, account_id) do
        {:ok, response, _body} ->
          {:ok, response}

        {:error, %ProviderError{class: :login}} when config.source == :kogen_owned ->
          with {:ok, refreshed} <-
                 Refresh.force(
                   config.credential_root,
                   config.backend,
                   config.label,
                   token,
                   proxy_env: config.proxy_env
                 ),
               {:ok, response, _body} <- execute(config, request, refreshed.access_token, nil) do
            {:ok, response}
          else
            {:error, reason} when reason in [:invalid_proxy, :proxy_auth_unsupported] ->
              transport_error(reason)

            {:error, _reason} ->
              login_error("ChatGPT rejected this session; run `kogen provider login chatgpt`.")
          end

        error ->
          error
      end
    end
  end

  defp credential_for_request(%Config{source: :kogen_owned} = config) do
    case Refresh.access_token(
           config.credential_root,
           config.backend,
           config.label,
           proxy_env: config.proxy_env
         ) do
      {:ok, credentials} ->
        {:ok, credentials.access_token, nil}

      {:error, reason} when reason in [:invalid_proxy, :proxy_auth_unsupported] ->
        transport_error(reason)

      {:error, _reason} ->
        login_error("ChatGPT login is unavailable; run `kogen provider login chatgpt`.")
    end
  end

  defp credential_for_request(%Config{
         source: :custom,
         credential_path: nil,
         access_token: token,
         account_id: account_id
       })
       when is_binary(token) and is_binary(account_id) do
    {:ok, token, account_id}
  end

  defp credential_for_request(%Config{source: :custom, credential_path: path}) do
    case Auth.load(path) do
      {:ok, credentials} ->
        {:ok, credentials.access_token, credentials.account_id}

      {:error, _reason} ->
        login_error("The configured ChatGPT credential is missing or invalid.")
    end
  end

  defp execute(config, request, token, account_id) do
    mode = if config.source == :kogen_owned, do: :siwc, else: :codex

    with {:ok, body} <- Codec.encode_request(request, mode),
         {:ok, response} <-
           Transport.post_stream(
             config.endpoint,
             headers(config, token, account_id),
             body,
             config.timeout_ms,
             proxy_env: config.proxy_env,
             first_byte_ms: config.first_byte_timeout_ms,
             total_ms: config.total_timeout_ms,
             on_first_byte: request.on_first_byte
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

  defp handle_response(%Transport.Response{status: status, body: body, chunks: chunks})
       when status in 200..299 do
    stream = Enum.reduce(chunks, Codec.new_stream(), &Codec.feed(&2, &1))

    case Codec.finish(stream) do
      {:ok, response} -> {:ok, response, body}
      error -> error
    end
  end

  defp handle_response(%Transport.Response{status: status, body: body}),
    do: response_error(status, body)

  defp headers(%Config{source: :kogen_owned}, token, _account_id) do
    [
      {"authorization", "Bearer " <> token},
      {"accept", "text/event-stream"},
      {"user-agent", "kogen/0.1"}
    ]
  end

  defp headers(_config, token, account_id) do
    [
      {"authorization", "Bearer " <> token},
      {"chatgpt-account-id", account_id},
      {"openai-beta", "responses=experimental"},
      {"originator", "kogen"},
      {"accept", "text/event-stream"},
      {"user-agent", "kogen/0.1"}
    ]
  end

  defp valid_config?(%Config{source: :kogen_owned} = config) do
    is_binary(config.credential_root) and config.backend in [:file, :keychain] and
      is_binary(config.label) and is_binary(config.endpoint) and valid_timeouts?(config)
  end

  defp valid_config?(%Config{source: :custom} = config) do
    custom_token? = is_binary(config.access_token) and config.access_token != ""

    is_binary(config.endpoint) and valid_timeouts?(config) and
      (is_binary(config.credential_path) or custom_token?)
  end

  defp valid_config?(_config), do: false
  defp valid_timeout?(timeout), do: is_integer(timeout) and timeout > 0

  defp valid_timeouts?(config) do
    Enum.all?(
      [config.timeout_ms, config.first_byte_timeout_ms, config.total_timeout_ms],
      &valid_timeout?/1
    )
  end

  defp response_error(401, _body) do
    provider_error(:login, "ChatGPT rejected the login; sign in again.")
  end

  defp response_error(status, body) do
    cond do
      status == 429 or usage_limit_body?(body) ->
        provider_error(
          :usage_limit,
          "ChatGPT subscription usage limit reached. Manage usage: #{@manage_usage}"
        )

      status in 500..599 or overloaded_body?(body) ->
        provider_error(:overload, "ChatGPT service is temporarily overloaded.")

      status in 200..299 ->
        provider_error(:malformed, "ChatGPT returned a malformed response stream.")

      true ->
        provider_error(:malformed, "ChatGPT rejected the request (HTTP #{status}).")
    end
  end

  defp usage_limit_body?(body) do
    body = normalized_error_body(body)

    Enum.any?(
      [
        "subscription_sharing_usage_limit_exceeded",
        "usage_limit",
        "usage limit"
      ],
      &String.contains?(body, &1)
    )
  end

  defp overloaded_body?(body) do
    body = normalized_error_body(body)
    Enum.any?(["server_is_overloaded", "overloaded", "overload"], &String.contains?(body, &1))
  end

  defp normalized_error_body(body) do
    if String.valid?(body), do: String.downcase(body), else: ""
  end

  defp transport_error(:timeout), do: provider_error(:timeout, "ChatGPT request timed out.")

  defp transport_error(:too_large),
    do: provider_error(:malformed, "ChatGPT response stream exceeded the size limit.")

  defp transport_error(:transport),
    do: provider_error(:transport, "ChatGPT request could not connect.")

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
