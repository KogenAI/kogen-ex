defmodule Kogen.Diagnostics.Parser.CredoFailures do
  @moduledoc false

  alias Kogen.Diagnostics.Parser.Common

  def findings(output, log_path, workdir) do
    output = output <> "\n" <> log(log_path)

    output
    |> Common.clean()
    |> Common.lines()
    |> Enum.reduce({nil, []}, &line(&1, &2, workdir))
    |> elem(1)
    |> Enum.reverse()
  end

  defp log(nil), do: ""

  defp log(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> ""
    end
  end

  defp line(text, {kind, findings}, workdir) do
    cond do
      String.contains?(text, "Some source files were not parsed in the time allotted:") ->
        {:timeout, findings}

      String.contains?(text, "Some source files could not be parsed correctly and are excluded:") ->
        {:failure, findings}

      kind != nil ->
        file_line(text, kind, findings, workdir)

      true ->
        {nil, findings}
    end
  end

  defp file_line(text, kind, findings, workdir) do
    case Regex.run(~r/^\s*\d+\)\s+(.+\.exs?)\s*$/, text, capture: :all_but_first) do
      [path] ->
        finding =
          Common.finding(
            "credo",
            "parse_#{kind}",
            {Common.normalize_path(path, workdir), 1, 1},
            nil,
            message(kind)
          )

        {kind, [finding | findings]}

      nil ->
        {if(String.trim(text) == "", do: kind), findings}
    end
  end

  defp message(:timeout),
    do:
      "Credo parsing timed out; this file was not analyzed. Retry with the approved parse allowance; do not exclude the file."

  defp message(:failure),
    do:
      "Credo could not parse this file; it was excluded from analysis. Repair its syntax or retry the parser; do not exclude the file."
end
