defmodule Kogen.Diagnostics.Report do
  @moduledoc false
  alias Kogen.Contracts.Finding
  alias Kogen.Contracts.Redact

  def write(results, run_dir) do
    path =
      Path.join(run_dir, "gate-findings-#{System.unique_integer([:positive, :monotonic])}.json")

    checks = Enum.map(results, &Map.take(&1, [:name, :tool, :exit_level, :log_path]))

    findings =
      for result <- results,
          finding <- result.findings,
          do: finding |> Finding.record() |> Map.put(:check, result.name)

    report = %{schema: 1, checks: checks, findings: findings}

    with :ok <- File.mkdir_p(run_dir),
         :ok <-
           File.write(
             path,
             report |> wire() |> :json.encode() |> IO.iodata_to_binary() |> Redact.text()
           ) do
      {:ok, path}
    else
      {:error, reason} -> {:error, {:finding_report_failed, reason}}
    end
  end

  defp wire(nil), do: :null
  defp wire(value) when value in [true, false], do: value
  defp wire(value) when is_atom(value), do: Atom.to_string(value)

  defp wire(%Finding{} = value), do: value |> Map.from_struct() |> wire()

  defp wire(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), wire(item)} end)

  defp wire(value) when is_list(value), do: Enum.map(value, &wire/1)
  defp wire(value), do: value
end
