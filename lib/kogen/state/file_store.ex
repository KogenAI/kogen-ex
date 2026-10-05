defmodule Kogen.State.FileStore do
  @moduledoc false
  # Run journals are read by people and models, so no credential-shaped value is ever stored.

  alias Kogen.Contracts.Redact

  @spec atomic_write(Path.t(), binary()) :: :ok | {:error, term()}
  def atomic_write(path, contents) do
    temporary = "#{path}.#{System.unique_integer([:positive, :monotonic])}.tmp"

    with :ok <- File.write(temporary, Redact.text(contents), [:binary, :exclusive]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, _reason} = error ->
        _cleanup = File.rm(temporary)
        error
    end
  end

  @spec append_line(Path.t(), binary()) :: :ok | {:error, term()}
  def append_line(path, contents) do
    with {:ok, file} <- File.open(path, [:append, :binary]) do
      IO.binwrite(file, [Redact.text(contents), "\n"])

      case File.close(file) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
