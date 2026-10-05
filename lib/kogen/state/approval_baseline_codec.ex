defmodule Kogen.State.ApprovalBaselineCodec do
  @moduledoc false

  @spec encode([map()]) :: [map()]
  def encode(rows) do
    Enum.map(rows, fn %{name: name, status: status, findings: findings} ->
      %{
        name: name,
        status: status,
        findings:
          Enum.map(findings, fn %{path: path, kind: kind, id: id, tool: tool, message: message} ->
            %{path: path, kind: kind, id: id, tool: tool, message: message}
          end)
      }
    end)
  end

  @spec decode(term()) :: {:ok, [map()]} | {:error, :invalid_approval}
  def decode(rows) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, decoded} ->
      case decode_row(row) do
        {:ok, item} -> {:cont, {:ok, [item | decoded]}}
        :error -> {:halt, {:error, :invalid_approval}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  def decode(_rows), do: {:error, :invalid_approval}

  defp decode_row(%{"name" => name, "status" => status, "findings" => findings})
       when is_binary(name) and name != "" and is_list(findings) do
    with {:ok, status} <- status(status),
         {:ok, findings} <- decode_findings(findings),
         true <- status == :red or findings == [] do
      {:ok, %{name: name, status: status, findings: findings}}
    else
      _invalid -> :error
    end
  end

  defp decode_row(_row), do: :error

  defp decode_findings(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, decoded} ->
      case decode_finding(row) do
        {:ok, finding} -> {:cont, {:ok, [finding | decoded]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      :error -> :error
    end
  end

  defp decode_finding(%{
         "path" => path,
         "kind" => kind,
         "id" => id,
         "tool" => tool,
         "message" => message
       })
       when kind in ["rule", "test"] and is_binary(id) and is_binary(tool) and is_binary(message) do
    with {:ok, path} <- nullable_path(path) do
      kind = if kind == "test", do: :test, else: :rule
      {:ok, %{path: path, kind: kind, id: id, tool: tool, message: message}}
    end
  end

  defp decode_finding(_row), do: :error

  defp nullable_path(:null), do: {:ok, nil}
  defp nullable_path(nil), do: {:ok, nil}
  defp nullable_path(path) when is_binary(path), do: {:ok, path}
  defp nullable_path(_path), do: :error

  defp status("green"), do: {:ok, :green}
  defp status("red"), do: {:ok, :red}
  defp status(_status), do: :error
end
