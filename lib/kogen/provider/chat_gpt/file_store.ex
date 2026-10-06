defmodule Kogen.Provider.ChatGPT.FileStore do
  @moduledoc false

  @spec path(Path.t(), String.t()) :: Path.t()
  def path(root, label), do: Path.join([root, "credentials", "chatgpt-#{label}.json"])

  @spec path(Path.t(), String.t(), String.t()) :: Path.t()
  def path(root, provider, label),
    do: Path.join([root, "credentials", "#{provider}-#{label}.json"])

  @spec encrypted_path(Path.t(), String.t()) :: Path.t()
  def encrypted_path(root, label), do: encrypted_path(root, "chatgpt", label)

  @spec encrypted_path(Path.t(), String.t(), String.t()) :: Path.t()
  def encrypted_path(root, provider, label),
    do: Path.join([root, "credentials", "#{provider}-#{label}.enc"])

  @spec read_encrypted(Path.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_encrypted(root, label), do: read_encrypted(root, "chatgpt", label)

  @spec read_encrypted(Path.t(), String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_encrypted(root, provider, label), do: File.read(encrypted_path(root, provider, label))

  @spec write_encrypted(Path.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_encrypted(root, label, contents),
    do: write_encrypted(root, "chatgpt", label, contents)

  @spec write_encrypted(Path.t(), String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_encrypted(root, provider, label, contents) when is_binary(contents),
    do: atomic_write(encrypted_path(root, provider, label), contents)

  @spec delete_encrypted(Path.t(), String.t()) :: :ok | {:error, term()}
  def delete_encrypted(root, label), do: delete_encrypted(root, "chatgpt", label)

  @spec delete_encrypted(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_encrypted(root, provider, label) do
    case File.rm(encrypted_path(root, provider, label)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read(Path.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read(root, label), do: File.read(path(root, label))

  @spec write(Path.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write(root, label, contents) when is_binary(contents) do
    atomic_write(path(root, label), contents)
  end

  @spec delete(Path.t(), String.t()) :: :ok | {:error, term()}
  def delete(root, label) do
    case File.rm(path(root, label)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec atomic_write(Path.t(), binary()) :: :ok | {:error, term()}
  def atomic_write(path, contents) when is_binary(path) and is_binary(contents) do
    directory = Path.dirname(path)
    temporary = path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- write_private(temporary, contents),
         :ok <- File.rename(temporary, path),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(temporary)
        if reason == :eexist, do: {:error, :temporary_file_exists}, else: error
    end
  end

  defp write_private(path, contents) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- :file.change_mode(String.to_charlist(path), 0o600),
               :ok <- IO.binwrite(file, contents) do
            :file.sync(file)
          end

        case {result, File.close(file)} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close_result} -> {:error, reason}
          {:ok, {:error, reason}} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
