defmodule Kogen.Agents.Output do
  @moduledoc false

  def text([]), do: ""

  def text(records) do
    "Agents:\n" <>
      Enum.map_join(records, "", fn record ->
        "  #{record.id} #{record.role} Build=#{record.build} " <>
          "#{record.status} elapsed_ms=#{record.elapsed_ms} #{record.activity}\n" <>
          "    events: #{record.events_path}\n"
      end)
  end

  def json(records),
    do: Enum.map_join(records, "", &(encode(Map.put(record(&1), :type, "agent")) <> "\n"))

  def report(json, []), do: json

  def report(json, records) do
    json
    |> :json.decode()
    |> Map.put("agents", Enum.map(records, &record/1))
    |> encode()
  end

  defp record(value),
    do: Map.new(value, fn {key, value} -> {key, if(is_nil(value), do: :null, else: value)} end)

  defp encode(value), do: value |> :json.encode() |> IO.iodata_to_binary()
end
