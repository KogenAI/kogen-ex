defmodule Kogen.Grok.CredentialStore do
  @moduledoc false

  alias Kogen.Contracts.JSON
  alias Kogen.Contracts.Lock
  alias Kogen.Grok.CredentialStore.Profile
  alias Kogen.Provider.ChatGPT.FileStore
  alias Kogen.Provider.ChatGPT.KeychainStore

  @enforce_keys [:access_token, :refresh_token, :expires_at, :scopes, :client_id, :token_endpoint]
  defstruct [
    :access_token,
    :refresh_token,
    :expires_at,
    :scopes,
    :email,
    :client_id,
    :token_endpoint
  ]

  @type t :: %__MODULE__{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: pos_integer(),
          scopes: [String.t()],
          email: String.t() | nil,
          client_id: String.t(),
          token_endpoint: String.t()
        }

  @spec valid_label?(term()) :: boolean()
  def valid_label?(label) when is_binary(label),
    do: Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/, label)

  def valid_label?(_label), do: false

  defp valid_label(label),
    do: if(valid_label?(label), do: :ok, else: {:error, :invalid_account_label})

  @spec load(Path.t(), :file | :keychain, String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def load(root, backend, label, opts \\ []) when backend in [:file, :keychain] do
    with :ok <- valid_label(label),
         {:ok, contents} <- read(root, backend, label, opts),
         {:ok, json} <- decode_json(contents) do
      decode_credentials(json)
    end
  end

  @spec save(Path.t(), :file | :keychain, String.t(), t(), keyword()) ::
          :ok | {:error, term()}
  def save(root, backend, label, %__MODULE__{} = credentials, opts \\ [])
      when backend in [:file, :keychain] do
    with :ok <- valid_label(label),
         {:ok, contents} <- encode_credentials(credentials) do
      write(root, backend, label, contents, opts)
    end
  end

  @spec delete(Path.t(), :file | :keychain, String.t(), keyword()) :: :ok | {:error, term()}
  def delete(root, backend, label, opts \\ []) when backend in [:file, :keychain] do
    with :ok <- valid_label(label) do
      result =
        case backend do
          :file ->
            File.rm(file_path(root, label))

          :keychain ->
            KeychainStore.delete_for_provider(root, "grok", label, Keyword.get(opts, :keychain))
        end

      case result do
        {:error, :enoent} -> :ok
        other -> other
      end
    end
  end

  @spec file_path(Path.t(), String.t()) :: Path.t()
  def file_path(root, label), do: FileStore.path(root, "grok", label)

  @spec profile(Path.t(), String.t()) :: {:ok, Profile.t() | nil} | {:error, term()}
  def profile(root, label) do
    with :ok <- valid_label(label),
         {:ok, profiles} <- read_profiles(root) do
      value = profiles |> Map.get("grok", %{}) |> Map.get(label)
      decode_profile(value, label)
    end
  end

  @spec profiles(Path.t()) :: {:ok, [Profile.t()]} | {:error, term()}
  def profiles(root) do
    with {:ok, profiles} <- read_profiles(root),
         grok when is_map(grok) <- Map.get(profiles, "grok", %{}),
         {:ok, decoded} <- decode_profiles(grok) do
      {:ok, Enum.sort_by(decoded, & &1.label)}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  @spec update_profile(Path.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_profile(root, label, attributes) when is_map(attributes) do
    with :ok <- valid_label(label) do
      case Lock.with_lock(root, "profiles", fn -> put_profile(root, label, attributes) end) do
        {:ok, :ok} -> :ok
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read(root, :file, label, _opts), do: File.read(file_path(root, label))

  defp read(root, :keychain, label, opts),
    do: KeychainStore.read_for_provider(root, "grok", label, Keyword.get(opts, :keychain))

  defp write(root, :file, label, contents, _opts),
    do: FileStore.atomic_write(file_path(root, label), contents)

  defp write(root, :keychain, label, contents, opts),
    do:
      KeychainStore.write_for_provider(
        root,
        "grok",
        label,
        contents,
        Keyword.get(opts, :keychain)
      )

  defp encode_credentials(%__MODULE__{} = credentials) do
    json = %{
      "access_token" => credentials.access_token,
      "refresh_token" => credentials.refresh_token,
      "expires_at" => credentials.expires_at,
      "scopes" => credentials.scopes,
      "email" => credentials.email || :null,
      "client_id" => credentials.client_id,
      "token_endpoint" => credentials.token_endpoint
    }

    encode_json(json)
  end

  defp decode_credentials(json) do
    with access_token when is_binary(access_token) and access_token != "" <- json["access_token"],
         refresh_token when is_binary(refresh_token) and refresh_token != "" <-
           json["refresh_token"],
         expires_at when is_integer(expires_at) and expires_at > 0 <- json["expires_at"],
         scopes when is_list(scopes) <- json["scopes"],
         true <- Enum.all?(scopes, &is_binary/1),
         client_id when is_binary(client_id) and client_id != "" <- json["client_id"],
         token_endpoint when is_binary(token_endpoint) and token_endpoint != "" <-
           json["token_endpoint"],
         email when is_binary(email) or email == :null <- json["email"] do
      {:ok,
       %__MODULE__{
         access_token: access_token,
         refresh_token: refresh_token,
         expires_at: expires_at,
         scopes: scopes,
         email: if(email == :null, do: nil, else: email),
         client_id: client_id,
         token_endpoint: token_endpoint
       }}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp put_profile(root, label, attributes) do
    with {:ok, profiles} <- read_profiles(root),
         grok = Map.get(profiles, "grok", %{}),
         current = Map.get(grok, label, %{}),
         updated = Map.merge(current, string_keys(attributes)),
         profiles = Map.put(profiles, "grok", Map.put(grok, label, updated)),
         {:ok, contents} <- encode_json(profiles) do
      FileStore.atomic_write(Path.join(root, "profiles.json"), contents)
    end
  end

  defp decode_profiles(grok) do
    Enum.reduce_while(grok, {:ok, []}, fn {label, value}, {:ok, profiles} ->
      case decode_profile(value, label) do
        {:ok, profile} when not is_nil(profile) -> {:cont, {:ok, [profile | profiles]}}
        _invalid -> {:halt, {:error, :invalid_credentials}}
      end
    end)
  end

  defp decode_profile(nil, _label), do: {:ok, nil}

  defp decode_profile(values, label) when is_map(values) and is_binary(label) do
    email = values["email"]
    expires_at = values["expires_at"]
    signed_in = values["signed_in"]

    if (is_nil(email) or is_binary(email)) and
         (is_nil(expires_at) or (is_integer(expires_at) and expires_at > 0)) and
         (is_nil(signed_in) or is_boolean(signed_in)) do
      {:ok,
       %Profile{
         label: label,
         email: email,
         expires_at: expires_at,
         signed_in: signed_in == true
       }}
    else
      {:error, :invalid_credentials}
    end
  end

  defp decode_profile(_values, _label), do: {:error, :invalid_credentials}

  defp read_profiles(root) do
    case File.read(Path.join(root, "profiles.json")) do
      {:ok, contents} -> decode_json(contents)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp string_keys(attributes),
    do: Map.new(attributes, fn {key, value} -> {to_string(key), value} end)

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp encode_json(value) do
    {:ok, value |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    ArgumentError -> {:error, :invalid_credentials}
  end
end
