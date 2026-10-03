defmodule Kogen.Contracts.ShapeWarningCodec do
  @moduledoc false

  alias Kogen.Contracts.ShapeWarning

  @spec encode(String.t(), [ShapeWarning.t()]) :: binary()
  def encode(intent_sha256, warnings) when is_binary(intent_sha256) and is_list(warnings) do
    record = %{
      "intent_sha256" => intent_sha256,
      "warnings" => Enum.map(warnings, &warning_json/1)
    }

    record |> :json.encode() |> IO.iodata_to_binary()
  end

  @spec decode(binary(), String.t()) :: {:ok, [ShapeWarning.t()]} | {:error, :invalid}
  def decode(bytes, expected_hash) when is_binary(bytes) and is_binary(expected_hash) do
    case :json.decode(bytes) do
      %{"intent_sha256" => ^expected_hash, "warnings" => warnings} when is_list(warnings) ->
        decode_warnings(warnings)

      %{"intent_sha256" => hash, "warnings" => warnings}
      when is_binary(hash) and is_list(warnings) ->
        {:ok, []}

      _other ->
        {:error, :invalid}
    end
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp warning_json(%ShapeWarning{} = warning) do
    %{
      "code" => Atom.to_string(warning.code),
      "item_ids" => warning.item_ids,
      "message" => warning.message
    }
  end

  defp decode_warnings(warnings) do
    warnings
    |> Enum.reduce_while({:ok, []}, fn warning, {:ok, acc} ->
      case decode_warning(warning) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        :error -> {:halt, {:error, :invalid}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_warning(
         %{"code" => "shape_reclassified", "item_ids" => ids, "message" => message} = row
       )
       when map_size(row) == 3 and is_list(ids) and ids != [] and is_binary(message) do
    if Enum.all?(ids, &valid_item_id?/1) and String.trim(message) != "" do
      {:ok, %ShapeWarning{code: :shape_reclassified, item_ids: ids, message: message}}
    else
      :error
    end
  end

  defp decode_warning(_row), do: :error

  defp valid_item_id?(id), do: is_binary(id) and Regex.match?(~r/\AA\d+\z/, id)
end
