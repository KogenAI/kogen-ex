defmodule Kogen.Diagnostics.Parser do
  @moduledoc false
  import Kogen.Diagnostics.Parser.Common,
    only: [
      location: 1,
      normalize_path: 2,
      credo_symbol: 1,
      credo_rule: 1,
      credo_severity: 1,
      finding: 5,
      cli_line: 1,
      lines: 1,
      environment_text?: 1
    ]

  alias Kogen.Diagnostics.ExUnitDetails
  alias Kogen.Diagnostics.Parser.Compile
  alias Kogen.Diagnostics.Parser.Dialyzer

  @file_path ~r{((?:\$WORKDIR/|/)?[A-Za-z0-9_.$-]+(?:/[A-Za-z0-9_.$-]+)*\.exs?)\s*$}
  @credo_head ~r/^\[([FWCRD])\]\s*(?:[↗↘→]+\s*)?(.*)$/u
  @exunit_test ~r/^\s*\d+\)\s+test\s+(.+?)\s+\(([^)]+)\)\s*$/
  @exunit_setup ~r/^\s*\d+\)\s+([A-Z][A-Za-z0-9_.]+): failure on setup_all callback/
  def findings(output, "mixed", workdir) do
    parse_credo(output, workdir) ++
      Dialyzer.findings(output, workdir) ++
      parse_format(output, workdir) ++
      parse_exunit(output, workdir) ++
      Compile.findings(output, workdir)
  end

  def findings(output, "credo", workdir), do: parse_credo(output, workdir)
  def findings(output, "dialyzer", workdir), do: Dialyzer.findings(output, workdir)
  def findings(output, "format", workdir), do: parse_format(output, workdir)
  def findings(output, "exunit", workdir), do: parse_exunit(output, workdir)
  def findings(output, "compile", workdir), do: Compile.findings(output, workdir)

  def findings(output, _tool, workdir) do
    parse_credo(output, workdir) ++
      Dialyzer.findings(output, workdir) ++
      parse_format(output, workdir) ++
      parse_exunit(output, workdir) ++
      Compile.findings(output, workdir)
  end

  def dialyzer_summaries(output) do
    ~r/Total errors:[^\r\n]*/
    |> Regex.scan(output)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
  end

  defp parse_credo(output, workdir) do
    {current, findings} = Enum.reduce(lines(output), {nil, []}, &credo_line(&1, &2, workdir))

    finding = credo_finding(current, workdir)
    if finding, do: [finding | findings], else: findings
  end

  defp credo_line(line, {current, findings}, workdir) do
    line = cli_line(line)

    case Regex.run(@credo_head, line, capture: :all_but_first) do
      [severity, message] ->
        finding = credo_finding(current, workdir)
        next = %{severity: severity, message: [String.trim(message)], path: nil, symbol: nil}
        {next, if(finding, do: [finding | findings], else: findings)}

      nil ->
        credo_detail_line(line, current, findings, workdir)
    end
  end

  defp credo_detail_line(_line, nil, findings, _workdir), do: {nil, findings}

  defp credo_detail_line(line, current, findings, workdir) do
    case location(line) do
      {:ok, path, line_number, col, _tail} ->
        updated = %{
          current
          | path: normalize_path(path, workdir),
            symbol: credo_symbol(line)
        }

        finding = credo_finding(updated, workdir, line_number, col)
        {nil, [finding | findings]}

      :error ->
        if String.trim(line) == "" or line == "┃" do
          {current, findings}
        else
          {%{current | message: current.message ++ [line]}, findings}
        end
    end
  end

  defp credo_finding(nil, _workdir), do: nil
  defp credo_finding(current, workdir), do: credo_finding(current, workdir, nil, nil)

  defp credo_finding(current, _workdir, line, col) do
    message = current.message |> Enum.join(" ") |> String.replace(~r/\s+/, " ") |> String.trim()

    %{
      tool: "credo",
      rule: credo_rule(message),
      severity: credo_severity(current.severity),
      path: current.path,
      line: line,
      col: col,
      symbol: current.symbol,
      message: message
    }
  end

  defp parse_format(output, workdir) do
    if Regex.match?(~r/mix format failed|files are not formatted/i, output) do
      output
      |> lines()
      |> Enum.flat_map(fn line ->
        case Regex.run(@file_path, cli_line(line), capture: :all_but_first) do
          [path] ->
            [
              finding(
                "format",
                "unformatted",
                {normalize_path(path, workdir), nil, nil},
                nil,
                "run mix format <path>"
              )
            ]

          _other ->
            []
        end
      end)
    else
      []
    end
  end

  defp parse_exunit(output, workdir) do
    output
    |> lines()
    |> Enum.reduce({nil, []}, fn line, {current, findings} ->
      case exunit_header(cli_line(line)) do
        {:ok, header} ->
          finding = exunit_finding(current, workdir)
          {header, if(finding, do: [finding | findings], else: findings)}

        :error when is_map(current) ->
          {Map.update!(current, :lines, &[line | &1]), findings}

        :error ->
          {current, findings}
      end
    end)
    |> then(fn {current, findings} ->
      finding = exunit_finding(current, workdir)
      if finding, do: [finding | findings], else: findings
    end)
    |> Enum.reverse()
  end

  defp exunit_header(line) do
    case Regex.run(@exunit_test, line, capture: :all_but_first) do
      [name, module] ->
        {:ok, %{name: name, module: module, lines: [line]}}

      nil ->
        case Regex.run(@exunit_setup, line, capture: :all_but_first) do
          [module] -> {:ok, %{name: "setup_all", module: module, lines: [line]}}
          nil -> :error
        end
    end
  end

  defp exunit_finding(nil, _workdir), do: nil

  defp exunit_finding(current, workdir) do
    block = current.lines |> Enum.reverse() |> Enum.map(&cli_line/1)

    location =
      Enum.find_value(block, fn line ->
        case location(line) do
          {:ok, _path, _line, _col, _tail} = found -> found
          :error -> nil
        end
      end)

    {path, line_number, col} = exunit_location(location, workdir)
    headline = exunit_headline(block)
    left = ExUnitDetails.field(block, "left")
    right = ExUnitDetails.field(block, "right")
    message = ExUnitDetails.message(block, path, workdir)
    environmental? = block |> Enum.join("\n") |> environment_text?()

    %{
      explanation: Enum.join(block, "\n"),
      tool: "exunit",
      rule: exunit_rule(environmental?, assertion?(left, right, headline)),
      severity: if(environmental?, do: :warning, else: :error),
      path: path,
      line: line_number,
      col: col,
      symbol: "#{current.module} \"#{current.name}\"",
      message:
        if(environmental?,
          do: "environment noise, not a candidate failure: " <> message,
          else: message
        )
    }
  end

  defp assertion?(left, right, headline),
    do: not is_nil(left) or not is_nil(right) or String.contains?(headline, "Assertion")

  defp exunit_rule(true, _assertion?), do: "environment"
  defp exunit_rule(false, true), do: "assertion"
  defp exunit_rule(false, _assertion?), do: "failure"

  defp exunit_location({:ok, path, line_number, col, _tail}, workdir),
    do: {normalize_path(path, workdir), line_number, col}

  defp exunit_location(_location, _workdir), do: {nil, nil, nil}

  defp exunit_headline(lines) do
    Enum.find_value(lines, "test failed", fn line ->
      cond do
        String.contains?(line, "Assertion") -> String.trim(line)
        String.contains?(line, "match (=) failed") -> String.trim(line)
        String.starts_with?(String.trim(line), "** (") -> String.trim(line)
        String.contains?(line, "Expected truthy") -> String.trim(line)
        true -> nil
      end
    end)
  end

end
