defmodule Kogen.Diagnostics.Renderer do
  @moduledoc false

  alias Kogen.Diagnostics
  alias Kogen.Diagnostics.DialyzerSummary
  alias Kogen.Diagnostics.Parser.Common

  @max_findings_per_tool 10
  @max_findings 20
  @tail_lines 8
  @tail_chars 600

  def model(results, options \\ []) do
    case Diagnostics.overall_exit_level(results) do
      level when level in [1, 2] ->
        findings = results |> Enum.flat_map(& &1.findings) |> deduplicate()
        dialyzer = Keyword.get(options, :dialyzer_summary)
        visible = visible(findings, dialyzer)
        hidden = findings |> hidden_findings(visible) |> hidden_notes(dialyzer)
        summaries = summaries(results, dialyzer)
        logs = results |> Enum.filter(&(&1.exit_level in [1, 2])) |> log_links()
        tail = first_tail(tail_results(results, dialyzer))
        level = Diagnostics.overall_exit_level(results)

        Enum.join(
          summaries ++
            Enum.map(visible, &render_finding/1) ++
            hidden ++
            report_link(options) ++ logs ++ tail ++ [summary_line(results, findings, level)],
          "\n"
        )

      _clean_or_environment ->
        ""
    end
  end

  def with_changes("", _changed_ranges), do: ""
  def with_changes(feedback, nil), do: feedback

  def with_changes(feedback, changed_ranges) when is_function(changed_ranges, 0) do
    case changed_ranges.() do
      {:ok, [_ | _] = ranges} ->
        feedback <>
          "\nCandidate changes relative to Build base:\n" <>
          Enum.join(Enum.take(ranges, 30), "\n")

      _other ->
        feedback
    end
  end

  defp visible(findings, nil), do: visible_findings(findings)

  defp visible(findings, summary) do
    other = findings |> Enum.reject(&(&1.tool == "dialyzer")) |> visible_findings()
    Enum.take(summary.first ++ other, @max_findings)
  end

  defp summaries(results, nil),
    do: results |> Enum.flat_map(& &1.dialyzer_summaries) |> Enum.uniq()

  defp summaries(_results, summary), do: DialyzerSummary.lines(summary)

  defp tail_results(results, nil), do: results

  defp tail_results(results, _summary) do
    Enum.reject(results, fn result ->
      result.tool == "dialyzer" or
        (result.findings != [] and Enum.all?(result.findings, &(&1.tool == "dialyzer")))
    end)
  end

  defp hidden_notes(hidden, nil), do: hidden

  defp hidden_notes(hidden, _summary),
    do: Enum.map(hidden, &String.replace(&1, "(--all)", "(complete report)"))

  defp report_link(options) do
    case Keyword.get(options, :report_path) do
      path when is_binary(path) -> ["complete findings: #{path}"]
      _missing -> []
    end
  end

  def environment(results) do
    unavailable = Enum.filter(results, &(&1.exit_level == 3))

    reasons =
      unavailable |> Enum.map(&"#{&1.name}: #{&1.reason || "could not check"}") |> Enum.uniq()

    levels = Enum.map_join(results, ", ", &"#{&1.name}=#{&1.exit_level}")

    Enum.join(
      ["gate: could not check (steps #{levels}); exit 3"] ++ reasons ++ log_links(unavailable),
      "\n"
    )
  end

  defp deduplicate(findings) do
    Enum.uniq_by(findings, fn finding ->
      {finding.tool, finding.rule, finding.path, finding.line, finding.col, finding.symbol,
       String.downcase(String.replace(finding.message, ~r/\s+/, " "))}
    end)
  end

  defp visible_findings(findings) do
    findings
    |> Enum.group_by(& &1.tool)
    |> Enum.sort_by(fn {tool, _items} -> tool_order(tool) end)
    |> Enum.flat_map(fn {_tool, items} -> Enum.take(items, @max_findings_per_tool) end)
    |> Enum.take(@max_findings)
  end

  defp hidden_findings(findings, visible) do
    visible_ids = MapSet.new(visible, &finding_id/1)

    findings
    |> Enum.reject(&MapSet.member?(visible_ids, finding_id(&1)))
    |> Enum.group_by(& &1.tool)
    |> Enum.sort_by(fn {tool, _items} -> tool_order(tool) end)
    |> Enum.map(fn {tool, items} -> "… #{length(items)} more #{tool} findings (--all)" end)
  end

  defp finding_id(finding),
    do:
      {finding.tool, finding.rule, finding.path, finding.line, finding.col, finding.symbol,
       finding.message}

  defp render_finding(finding) do
    location =
      case {finding.path, finding.line, finding.col} do
        {path, line, col} when is_binary(path) and is_integer(line) and is_integer(col) ->
          "#{path}:#{line}:#{col}: "

        {path, line, _col} when is_binary(path) and is_integer(line) ->
          "#{path}:#{line}: "

        {path, _line, _col} when is_binary(path) ->
          "#{path}: "

        _other ->
          "location unavailable: "
      end

    symbol = if finding.symbol, do: "#{finding.symbol}: ", else: ""

    "#{location}#{severity(finding.severity)}: [#{finding.tool}/#{finding.rule || "unknown"}] #{symbol}#{Common.truncate(finding.message)}#{hint(finding)}"
  end

  defp hint(%{hint: hint}) when is_binary(hint), do: " Hint: " <> Common.truncate(hint, 120)
  defp hint(_finding), do: ""

  defp summary_line(results, findings, level) do
    errors = Enum.count(findings, &(&1.severity == :error))
    warnings = Enum.count(findings, &(&1.severity == :warning))
    notes = Enum.count(findings, &(&1.severity == :note))

    tools =
      findings
      |> Enum.group_by(& &1.tool)
      |> Enum.sort_by(fn {tool, _items} -> tool_order(tool) end)
      |> Enum.map_join(", ", fn {tool, items} -> "#{tool} #{length(items)}" end)

    tools = if tools == "", do: "no findings", else: tools
    levels = Enum.map_join(results, ", ", &"#{&1.name}=#{&1.exit_level}")

    "gate: #{errors} errors, #{warnings} warnings, #{notes} notes (#{tools}); steps #{levels}; exit #{level}"
  end

  defp log_links(results) do
    results
    |> Enum.map(fn result -> if is_binary(result.log_path), do: "raw log: #{result.log_path}" end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp first_tail(results) do
    case Enum.find(results, &(&1.exit_level in [1, 2])) do
      nil -> []
      result -> ["raw tail (first failed step #{result.name}):"] ++ raw_tail(result.output)
    end
  end

  defp raw_tail(output) do
    output
    |> String.split("\n")
    |> Enum.take(-@tail_lines)
    |> Enum.join("\n")
    |> sanitize_tail()
    |> truncate_tail()
    |> case do
      "" -> ["(empty)"]
      tail -> String.split(tail, "\n")
    end
  end

  defp sanitize_tail(output) do
    output
    |> String.replace(~r{/var/folders/[^\s"']+}, "$TMPDIR")
    |> String.replace(~r{/Users/[^\s"']+}, "$HOME/<path>")
  end

  defp truncate_tail(value) do
    if String.length(value) > @tail_chars,
      do: "…" <> String.slice(value, String.length(value) - @tail_chars + 1, @tail_chars - 1),
      else: value
  end

  defp severity(:warning), do: "warning"
  defp severity(:note), do: "note"
  defp severity(_severity), do: "error"

  defp tool_order("dialyzer"), do: 0
  defp tool_order("compile"), do: 1
  defp tool_order("credo"), do: 2
  defp tool_order("format"), do: 3
  defp tool_order("exunit"), do: 4
  defp tool_order(tool), do: 5 + :erlang.phash2(tool)
end
