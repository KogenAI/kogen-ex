defmodule Kogen.Checks.Feedback.Parser do
  @moduledoc false
  import Kogen.Checks.Feedback.Parser.Common,
    only: [
      location: 1,
      normalize_path: 2,
      credo_symbol: 1,
      credo_rule: 1,
      credo_severity: 1,
      finding: 5,
      truncate: 1,
      truncate: 2,
      cli_line: 1,
      lines: 1,
      environment_text?: 1
    ]

  alias Kogen.Checks.Feedback.Parser.Compile

  @file_path ~r{((?:\$WORKDIR/|/)?[A-Za-z0-9_.$-]+(?:/[A-Za-z0-9_.$-]+)*\.exs?)\s*$}
  @credo_head ~r/^\[([FWCRD])\]\s*(?:[↗↘→]+\s*)?(.*)$/u
  @exunit_test ~r/^\s*\d+\)\s+test\s+(.+?)\s+\(([^)]+)\)\s*$/
  @exunit_setup ~r/^\s*\d+\)\s+([A-Z][A-Za-z0-9_.]+): failure on setup_all callback/
  def findings(output, "mixed", workdir) do
    parse_credo(output, workdir) ++
      parse_dialyzer(output, workdir) ++
      parse_format(output, workdir) ++
      parse_exunit(output, workdir) ++
      Compile.findings(output, workdir)
  end

  def findings(output, "credo", workdir), do: parse_credo(output, workdir)
  def findings(output, "dialyzer", workdir), do: parse_dialyzer(output, workdir)
  def findings(output, "format", workdir), do: parse_format(output, workdir)
  def findings(output, "exunit", workdir), do: parse_exunit(output, workdir)
  def findings(output, "compile", workdir), do: Compile.findings(output, workdir)

  def findings(output, _tool, workdir) do
    parse_credo(output, workdir) ++
      parse_dialyzer(output, workdir) ++
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
    message = current.message |> Enum.join(" ") |> String.replace(~r/\s+/, " ") |> truncate()

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

  defp parse_dialyzer(output, workdir) do
    output
    |> lines()
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      case diagnostic_location(cli_line(line)) do
        {:ok, path, line_number, col, rule} ->
          message = diagnostic_message(output, index, rule)

          [
            "dialyzer"
            |> finding(rule, {path, line_number, col}, nil, message)
            |> Map.put(:path, normalize_path(path, workdir))
          ]

        :error ->
          []
      end
    end)
    |> Enum.sort_by(&{&1.path || "", &1.line || 0, &1.col || 0})
  end

  defp diagnostic_location(line) do
    case if(Regex.match?(~r/\.exs?:\d+:\d+:/, line), do: location(line), else: :error) do
      {:ok, path, line_number, col, tail} when col > 0 and tail != "" ->
        case String.split(String.trim(tail), ~r/\s+/, parts: 2) do
          [rule | _rest] ->
            if Regex.match?(~r/^[a-z][a-z0-9_]*$/, rule),
              do: {:ok, path, line_number, col, rule},
              else: :error

          [] ->
            :error
        end

      _other ->
        :error
    end
  end

  defp diagnostic_message(output, index, rule) do
    output
    |> lines()
    |> Enum.drop(index + 1)
    |> Enum.take_while(fn line ->
      clean_line = cli_line(line)

      String.trim(clean_line) != "" and not String.contains?(clean_line, "Total errors:") and
        diagnostic_location(clean_line) == :error
    end)
    |> Enum.take(2)
    |> Enum.map(&String.trim(cli_line(&1)))
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> rule
      message -> Enum.join(message, " ")
    end
    |> truncate()
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
                {normalize_path(path, workdir), 1, 1},
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
    left = labeled_value(block, "left:")
    right = labeled_value(block, "right:")
    message = assertion_message(headline, left, right)
    environmental? = block |> Enum.join("\n") |> environment_text?()

    %{
      tool: "exunit",
      rule: exunit_rule(environmental?, assertion?(left, right, headline)),
      severity: if(environmental?, do: :warning, else: :error),
      path: path,
      line: line_number,
      col: col,
      symbol: "#{current.module} \"#{truncate(current.name, 100)}\"",
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

  defp labeled_value(lines, label) do
    Enum.find_value(lines, fn line ->
      case String.split(String.trim(line), label, parts: 2) do
        ["", value] -> truncate(String.trim(value), 80)
        _other -> nil
      end
    end)
  end

  defp assertion_message(headline, nil, nil), do: truncate(headline)
  defp assertion_message(headline, left, nil), do: truncate("#{headline}; left: #{left}")
  defp assertion_message(headline, nil, right), do: truncate("#{headline}; right: #{right}")

  defp assertion_message(headline, left, right),
    do: truncate("#{headline}; left: #{left}; right: #{right}")
end
