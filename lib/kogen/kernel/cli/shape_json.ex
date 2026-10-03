defmodule Kogen.Kernel.CLI.ShapeJson do
  @moduledoc false

  alias Kogen.Contracts.ShapeWarning

  @spec encode(map()) :: binary()
  def encode(result) when is_map(result) do
    %{
      "slug" => result.slug,
      "status" => "valid",
      "rounds" => result.rounds,
      "intent_path" => result.intent_path,
      "acceptance_path" => result.acceptance_path,
      "transcript_path" => result.transcript_path,
      "warnings" => Enum.map(result.warnings, &warning_json/1),
      "usage" => Enum.map(result.calls, &call_json/1)
    }
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp warning_json(%ShapeWarning{} = warning) do
    %{
      "code" => Atom.to_string(warning.code),
      "item_ids" => warning.item_ids,
      "message" => warning.message
    }
  end

  defp call_json(call) do
    %{
      "stage" => Atom.to_string(call.stage),
      "model" => call.model,
      "effort" => call.effort,
      "tokens" => Map.new(call.tokens, fn {key, value} -> {Atom.to_string(key), value} end),
      "wall_ms" => call.wall_ms
    }
  end
end
