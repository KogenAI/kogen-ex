defmodule Kogen.Agents.Codec do
  @moduledoc false

  @fields ~w(id parent_id project build role activity status started_at updated_at finished_at outcome)a

  def encode(value),
    do:
      value
      |> Map.new(fn {k, v} -> {k, if(is_nil(v), do: :null, else: v)} end)
      |> :json.encode()
      |> IO.iodata_to_binary()

  def read(path) do
    with {:ok, binary} <- File.read(path) do
      decode(binary)
    end
  end

  defp decode(binary) do
    case :json.decode(binary) do
      value when is_map(value) -> record(atom_keys(value, @fields))
      _other -> {:error, :invalid_agent_record}
    end
  rescue
    ArgumentError -> {:error, :invalid_agent_record}
  end

  defp record(value) do
    strings = [:id, :project, :build, :role, :activity, :status]
    integers = [:started_at, :updated_at]

    if Enum.all?(strings, &is_binary(Map.fetch!(value, &1))) and
         Enum.all?(integers, &is_integer(Map.fetch!(value, &1))) and
         (is_nil(value.finished_at) or is_integer(value.finished_at)),
       do: {:ok, value},
       else: {:error, :invalid_agent_record}
  end

  defp atom_keys(value, fields) do
    Map.new(fields, fn key -> {key, null(Map.get(value, Atom.to_string(key)))} end)
  end

  defp null(:null), do: nil
  defp null(value), do: value

  def build(run_dir), do: find_build(run_dir, Path.basename(run_dir))

  defp find_build(run_dir, fallback) do
    case File.read(Path.join(run_dir, "run.json")) do
      {:ok, binary} -> Map.get(:json.decode(binary), "run_id", fallback)
      {:error, :enoent} -> ancestor_build(run_dir, fallback)
      {:error, _reason} -> Path.basename(run_dir)
    end
  end

  defp ancestor_build(run_dir, fallback) do
    parent = Path.dirname(run_dir)
    if parent == run_dir, do: fallback, else: find_build(parent, fallback)
  end
end
