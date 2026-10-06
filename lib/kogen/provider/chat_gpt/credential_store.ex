defmodule Kogen.Provider.ChatGPT.CredentialStore do
  @moduledoc false

  alias Kogen.Accounts.Store, as: AccountStore
  alias Kogen.Contracts.JSON
  alias Kogen.Provider.ChatGPT.CredentialStore.Profile
  alias Kogen.Provider.ChatGPT.FileStore
  alias Kogen.Provider.ChatGPT.KeychainStore
  alias Kogen.Provider.ChatGPT.Lock

  @enforce_keys [
    :client_id,
    :access_token,
    :refresh_token,
    :id_token,
    :expires_at,
    :scopes,
    :subject,
    :host_id
  ]
  defstruct [
    :client_id,
    :access_token,
    :refresh_token,
    :id_token,
    :expires_at,
    :scopes,
    :subject,
    :email,
    :host_id
  ]

  @type t :: %__MODULE__{
          client_id: String.t(),
          access_token: String.t(),
          refresh_token: String.t(),
          id_token: String.t(),
          expires_at: pos_integer(),
          scopes: [String.t()],
          subject: String.t(),
          email: String.t() | nil,
          host_id: String.t()
        }

  @spec valid_label?(term()) :: boolean()
  def valid_label?(label) when is_binary(label),
    do: Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/, label)

  def valid_label?(_label), do: false

  @spec load(Path.t(), :file | :keychain, String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def load(root, backend, label, opts \\ []) when backend in [:file, :keychain] do
    with :ok <- valid_label(label),
         {:ok, contents} <- read(root, backend, label, opts),
         {:ok, json} <- decode_json(contents) do
      decode_credentials(json)
    end
  end

  @spec save(Path.t(), :file | :keychain, String.t(), t(), keyword()) :: :ok | {:error, term()}
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
      case backend do
        :file -> FileStore.delete(root, label)
        :keychain -> KeychainStore.delete(root, label, Keyword.get(opts, :keychain))
      end
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

  @spec profiles(Path.t()) :: {:ok, [Profile.t()]} | {:error, term()}
  def profiles(root) do
    case read_profiles(root) do
      {:ok, all} ->
        decode_profiles(Map.get(all, "chatgpt", %{}))

      error ->
        error
    end
  end

  @typedoc "The default account and each project's own account (keyed by canonical path)."
  @type account_choices :: %{default: String.t() | nil, projects: %{Path.t() => String.t()}}

  @doc """
  Reads `<root>/accounts.yaml`, this machine's account choices. Never committed to a repo:
  every user has their own logins.
  """
  @spec account_choices(Path.t()) :: {:ok, account_choices()} | {:error, term()}
  def account_choices(root), do: AccountStore.account_choices(root, "chatgpt")

  @spec account_choices(Path.t(), String.t()) :: {:ok, account_choices()} | {:error, term()}
  def account_choices(root, provider), do: AccountStore.account_choices(root, provider)

  @doc "Sets the default account, or one project's; forgets projects that no longer exist."
  @spec put_account_choice(Path.t(), :default | {:project, Path.t()}, String.t()) ::
          :ok | {:error, term()}
  def put_account_choice(root, target, label),
    do: AccountStore.put_account_choice(root, "chatgpt", target, label)

  @spec put_account_choice(Path.t(), :default | {:project, Path.t()}, String.t(), String.t()) ::
          :ok | {:error, term()}
  def put_account_choice(root, target, label, provider),
    do: AccountStore.put_account_choice(root, provider, target, label)

  @spec profile(Path.t(), String.t()) :: {:ok, Profile.t() | nil} | {:error, term()}
  def profile(root, label) do
    with :ok <- valid_label(label),
         {:ok, profiles} <- read_profiles(root) do
      profiles
      |> Map.get("chatgpt", %{})
      |> profile_for_label(label)
    end
  end

  @doc false
  @spec file_path(Path.t(), String.t()) :: Path.t()
  def file_path(root, label), do: FileStore.path(root, label)

  defp valid_label(label) do
    if valid_label?(label), do: :ok, else: {:error, :invalid_account_label}
  end

  defp read(root, :file, label, _opts), do: FileStore.read(root, label)

  defp read(root, :keychain, label, opts),
    do: KeychainStore.read(root, label, Keyword.get(opts, :keychain))

  defp write(root, :file, label, contents, _opts), do: FileStore.write(root, label, contents)

  defp write(root, :keychain, label, contents, opts),
    do: KeychainStore.write(root, label, contents, Keyword.get(opts, :keychain))

  defp encode_credentials(%__MODULE__{} = credentials) do
    json = %{
      "client_id" => credentials.client_id,
      "access_token" => credentials.access_token,
      "refresh_token" => credentials.refresh_token,
      "id_token" => credentials.id_token,
      "expires_at" => credentials.expires_at,
      "scopes" => credentials.scopes,
      "subject" => credentials.subject,
      "email" => credentials.email || :null,
      "host_id" => credentials.host_id
    }

    encode_json(json)
  end

  defp decode_credentials(json), do: do_decode_credentials(json)

  defp do_decode_credentials(json) do
    with client_id when is_binary(client_id) <- json["client_id"],
         access_token when is_binary(access_token) <- json["access_token"],
         refresh_token when is_binary(refresh_token) <- json["refresh_token"],
         id_token when is_binary(id_token) <- json["id_token"],
         expires_at when is_integer(expires_at) and expires_at > 0 <- json["expires_at"],
         scopes when is_list(scopes) <- json["scopes"],
         true <- Enum.all?(scopes, &is_binary/1),
         subject when is_binary(subject) <- json["subject"],
         host_id when is_binary(host_id) <- json["host_id"],
         email when is_binary(email) or email == :null <- json["email"] do
      {:ok,
       %__MODULE__{
         client_id: client_id,
         access_token: access_token,
         refresh_token: refresh_token,
         id_token: id_token,
         expires_at: expires_at,
         scopes: scopes,
         subject: subject,
         email: if(email == :null, do: nil, else: email),
         host_id: host_id
       }}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp put_profile(root, label, attributes) do
    with {:ok, profiles} <- read_profiles(root),
         accounts = Map.get(profiles, "chatgpt", %{}),
         current = Map.get(accounts, label, %{}),
         updated = Map.merge(current, string_keys(attributes)),
         profiles = Map.put(profiles, "chatgpt", Map.put(accounts, label, updated)),
         {:ok, contents} <- encode_json(profiles) do
      FileStore.atomic_write(Path.join(root, "profiles.json"), contents)
    end
  end

  defp decode_profiles(accounts) when is_map(accounts) do
    accounts
    |> Enum.reduce_while({:ok, []}, fn {label, value}, {:ok, profiles} ->
      case decode_profile(value, label) do
        {:ok, profile} -> {:cont, {:ok, [profile | profiles]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, profiles} -> {:ok, Enum.sort_by(profiles, & &1.label)}
      error -> error
    end
  end

  defp decode_profiles(_accounts), do: {:error, :invalid_credentials}

  defp profile_for_label(accounts, label) when is_map(accounts),
    do: decode_profile(Map.get(accounts, label), label)

  defp profile_for_label(_accounts, _label), do: {:error, :invalid_credentials}

  defp decode_profile(nil, _label), do: {:ok, nil}

  defp decode_profile(values, label) when is_map(values) and is_binary(label) do
    with :ok <- optional_string(values, "client_id"),
         :ok <- optional_string(values, "subject"),
         :ok <- optional_string(values, "email"),
         :ok <- optional_string(values, "auth_source"),
         :ok <- optional_expiry(values, "expires_at"),
         :ok <- optional_boolean(values, "signed_in"),
         :ok <- optional_boolean(values, "plan_usage"),
         :ok <- optional_boolean(values, "notice_shown"),
         :ok <- optional_boolean(values, "remote_revoked") do
      {:ok,
       %Profile{
         label: label,
         client_id: values["client_id"],
         subject: values["subject"],
         email: values["email"],
         expires_at: values["expires_at"],
         auth_source: values["auth_source"],
         signed_in: values["signed_in"] == true,
         plan_usage: values["plan_usage"] == true,
         notice_shown: values["notice_shown"] == true,
         remote_revoked: values["remote_revoked"]
       }}
    end
  end

  defp decode_profile(_values, _label), do: {:error, :invalid_credentials}

  defp optional_string(values, key) do
    case values[key] do
      nil -> :ok
      value when is_binary(value) -> :ok
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp optional_expiry(values, key) do
    case values[key] do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp optional_boolean(values, key) do
    case values[key] do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _invalid -> {:error, :invalid_credentials}
    end
  end

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
