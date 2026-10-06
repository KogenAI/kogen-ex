defmodule Kogen.CheckLearning.Store do
  @moduledoc false
  alias Kogen.Contracts.Redact

  @spec write(Path.t(), map()) :: :ok | {:error, term()}
  def write(path, data), do: write_text(path, JSON.encode!(data))

  @spec write_text(Path.t(), String.t()) :: :ok | {:error, term()}
  def write_text(path, bytes) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, Redact.text(bytes)),
         do: File.rename(temporary, path)
  end

  @spec digest(binary()) :: String.t()
  def digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @spec read_source(Path.t(), Path.t()) :: {:ok, binary()} | {:error, term()}
  def read_source(root, path) do
    if safe_path?(path) and regular_path?(root, Path.split(path)) do
      File.read(Path.join(root, path))
    else
      {:error, {:unsafe_sample_path, path}}
    end
  end

  @spec safe_path?(term()) :: boolean()
  def safe_path?(path) when is_binary(path) do
    Path.type(path) == :relative and not String.contains?(path, [<<0>>, "\n", "\r"]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", "..", ".git"]))
  end

  def safe_path?(_path), do: false

  defp regular_path?(root, [file]),
    do: match?({:ok, %{type: :regular}}, File.lstat(Path.join(root, file)))

  defp regular_path?(root, [directory | rest]) do
    next = Path.join(root, directory)
    match?({:ok, %{type: :directory}}, File.lstat(next)) and regular_path?(next, rest)
  end
end
