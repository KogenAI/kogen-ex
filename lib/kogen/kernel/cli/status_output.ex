defmodule Kogen.Kernel.CLI.StatusOutput do
  @moduledoc false

  def text([]), do: "no Intents\n"

  def text(statuses) do
    Enum.map_join(statuses, "", fn status ->
      "#{status.slug} #{status.status} run=#{value(status.run_id)} landed=#{value(status.landed_sha)}\n"
    end)
  end

  def json(statuses) do
    records =
      Enum.map(statuses, fn status ->
        Map.new([
          {"slug", status.slug},
          {"status", Atom.to_string(status.status)},
          {"run_id", json_value(status.run_id)},
          {"landed_sha", json_value(status.landed_sha)}
        ])
      end)

    json = records |> :json.encode() |> IO.iodata_to_binary()
    json <> "\n"
  end

  defp value(nil), do: "-"
  defp value(value), do: value

  defp json_value(nil), do: :null
  defp json_value(value), do: value
end
