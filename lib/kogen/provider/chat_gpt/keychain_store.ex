defmodule Kogen.Provider.ChatGPT.KeychainStore do
  @moduledoc false

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Provider.ChatGPT.FileStore

  @security "/usr/bin/security"
  @service "kogen"
  @magic "KOGEN-CHATGPT-1\n"
  @key_bytes 32
  @nonce_bytes 12
  @tag_bytes 16
  @timeout_ms 15_000

  @spec available?() :: boolean()
  def available?, do: File.regular?(@security)

  @spec read(Path.t(), String.t(), Path.t() | nil) :: {:ok, binary()} | {:error, term()}
  def read(root, label, keychain \\ nil) when is_binary(root) and is_binary(label) do
    read_for_provider(root, "chatgpt", label, keychain)
  end

  @spec read_for_provider(Path.t(), String.t(), String.t(), Path.t() | nil) ::
          {:ok, binary()} | {:error, term()}
  def read_for_provider(root, provider, label, keychain \\ nil)
      when is_binary(root) and is_binary(provider) and is_binary(label) do
    with :ok <- prepare_root(root) do
      case FileStore.read_encrypted(root, provider, label) do
        {:ok, encrypted} ->
          with {:ok, key} <- read_key(root, provider, label, keychain),
               do: decrypt(encrypted, key, provider, label)

        {:error, :enoent} ->
          read_legacy(root, provider, label, keychain)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec write(Path.t(), String.t(), binary(), Path.t() | nil) :: :ok | {:error, term()}
  def write(root, label, contents, keychain \\ nil)
      when is_binary(root) and is_binary(label) and is_binary(contents) do
    write_for_provider(root, "chatgpt", label, contents, keychain)
  end

  @spec write_for_provider(Path.t(), String.t(), String.t(), binary(), Path.t() | nil) ::
          :ok | {:error, term()}
  def write_for_provider(root, provider, label, contents, keychain \\ nil)
      when is_binary(root) and is_binary(provider) and is_binary(label) and is_binary(contents) do
    with :ok <- prepare_root(root),
         {:ok, key} <- key_for_write(root, provider, label, keychain),
         {:ok, encrypted} <- encrypt(contents, key, provider, label),
         :ok <- FileStore.write_encrypted(root, provider, label, encrypted),
         :ok <- verify_encrypted(root, provider, label, contents, key, keychain) do
      delete_item(root, legacy_account(provider, label), keychain)
    end
  end

  @spec delete(Path.t(), String.t(), Path.t() | nil) :: :ok | {:error, term()}
  def delete(root, label, keychain \\ nil) when is_binary(root) and is_binary(label) do
    delete_for_provider(root, "chatgpt", label, keychain)
  end

  @spec delete_for_provider(Path.t(), String.t(), String.t(), Path.t() | nil) ::
          :ok | {:error, term()}
  def delete_for_provider(root, provider, label, keychain \\ nil)
      when is_binary(root) and is_binary(provider) and is_binary(label) do
    with :ok <- prepare_root(root),
         :ok <- FileStore.delete_encrypted(root, provider, label),
         :ok <- delete_item(root, key_account(provider, label), keychain) do
      delete_item(root, legacy_account(provider, label), keychain)
    end
  end

  defp key_for_write(root, provider, label, keychain) do
    case read_key(root, provider, label, keychain) do
      {:ok, key} ->
        {:ok, key}

      # The `security` CLI treats a keychain operand after `-w` as the password
      # argument. A scoped test keychain therefore needs a seeded key; never
      # risk falling back to the user's default keychain for the test fixture.
      {:error, :not_found} when is_binary(keychain) ->
        {:error, :keychain_key_missing}

      {:error, :not_found} ->
        key = :crypto.strong_rand_bytes(@key_bytes)

        with :ok <- store_key(root, provider, label, key), do: {:ok, key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_key(root, provider, label, key) do
    encoded = Base.encode64(key)
    input = encoded <> "\n" <> encoded <> "\n"

    with {:ok, _output} <-
           run_security(add_args(key_account(provider, label)), input, root),
         {:ok, ^encoded} <- read_key_encoded(root, provider, label, nil) do
      :ok
    else
      {:ok, _different} -> {:error, :keychain_key_mismatch}
      {:error, :not_found} -> {:error, :keychain_key_missing}
      {:error, reason, _output} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_encrypted(root, provider, label, expected, key, keychain) do
    with {:ok, actual_key} <- read_key(root, provider, label, keychain),
         true <- actual_key == key,
         {:ok, encrypted} <- FileStore.read_encrypted(root, provider, label),
         {:ok, actual} <- decrypt(encrypted, actual_key, provider, label),
         true <- actual == expected do
      :ok
    else
      false -> {:error, :credential_verification_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_key(root, provider, label, keychain) do
    with {:ok, encoded} <- read_key_encoded(root, provider, label, keychain) do
      case Base.decode64(encoded) do
        {:ok, key} when byte_size(key) == @key_bytes -> {:ok, key}
        _invalid -> {:error, :keychain_key_invalid}
      end
    end
  end

  defp read_key_encoded(root, provider, label, keychain) do
    case command(
           root,
           generic_args("find-generic-password", key_account(provider, label), keychain, ["-w"])
         ) do
      {:ok, output} -> {:ok, String.trim(output)}
      error -> error
    end
  end

  defp read_legacy(root, provider, label, keychain) do
    case command(
           root,
           generic_args("find-generic-password", legacy_account(provider, label), keychain, ["-w"])
         ) do
      {:ok, output} -> decode_legacy(output)
      error -> error
    end
  end

  defp decode_legacy(output) do
    case Base.decode64(String.trim(output)) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :keychain_legacy_credential_invalid}
    end
  end

  defp encrypt(contents, key, provider, label) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        contents,
        label,
        @tag_bytes,
        true
      )

    {:ok, magic(provider) <> nonce <> tag <> ciphertext}
  rescue
    ArgumentError -> {:error, :credential_encryption_failed}
  end

  defp decrypt(encrypted, key, provider, label) do
    prefix = magic(provider)

    case encrypted do
      <<^prefix::binary, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
        ciphertext::binary>> ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, label, tag, false) do
          plaintext when is_binary(plaintext) -> {:ok, plaintext}
          :error -> {:error, :credential_decryption_failed}
        end

      _invalid ->
        {:error, :credential_file_invalid}
    end
  rescue
    ArgumentError -> {:error, :credential_decryption_failed}
  end

  defp delete_item(root, account, keychain) do
    case command(
           root,
           generic_args("delete-generic-password", account, keychain, [])
         ) do
      {:ok, _output} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp command(root, args) do
    case run_security(args, nil, root) do
      {:ok, output} ->
        {:ok, output}

      {:error, reason, output} ->
        if String.contains?(String.downcase(output), "could not be found"),
          do: {:error, :not_found},
          else: {:error, reason}
    end
  end

  defp generic_args(command, account, keychain, args) do
    [command, "-s", @service, "-a", account] ++ args ++ keychain_operand(keychain)
  end

  defp add_args(account), do: ["add-generic-password", "-U", "-s", @service, "-a", account, "-w"]

  defp keychain_operand(nil), do: []
  defp keychain_operand(keychain), do: [keychain]

  defp prepare_root(root) do
    with :ok <- File.mkdir_p(root), do: File.chmod(root, 0o700)
  end

  defp run_security(args, input, directory) do
    if available?() do
      opts = [cd: directory, env: %{}, timeout_ms: @timeout_ms]
      opts = if is_binary(input), do: Keyword.put(opts, :stdin, {:binary, input}), else: opts

      case Proc.run([@security | args], opts) do
        {:ok, %ProcResult{output_tail: output} = result} ->
          cond do
            password_mismatch?(output) ->
              {:error, :keychain_password_mismatch, output}

            result.timed_out ->
              {:error, :keychain_timeout, output}

            result.exit_status == 0 ->
              {:ok, output}

            true ->
              {:error, :keychain_unavailable, output}
          end

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, :keychain_unavailable, ""}
    end
  end

  defp password_mismatch?(output), do: String.contains?(String.downcase(output), "don't match")

  defp key_account(provider, label), do: provider <> ":" <> label <> ":key"
  defp legacy_account(provider, label), do: provider <> ":" <> label

  defp magic("chatgpt"), do: @magic
  defp magic(provider), do: "KOGEN-" <> String.upcase(provider) <> "-1\n"
end
