defmodule Kogen.Diagnostics.DialyzerSummary do
  @moduledoc false
  @buckets [:changed, :unchanged, :unknown_scope, :unavailable_locations]

  def summarize(results, changed_paths) do
    warnings =
      results |> Enum.flat_map(&warnings/1) |> Enum.uniq_by(&{&1.id, &1.path, &1.line, &1.col})

    groups = Enum.group_by(warnings, &bucket(&1, changed_paths))
    counts = Map.new(@buckets, &{&1, length(Map.get(groups, &1, []))})

    missing =
      results
      |> Enum.uniq_by(&{&1.name, &1.log_path, &1.output})
      |> Enum.map(&missing/1)
      |> Enum.sum()

    counts = Map.update!(counts, :unavailable_locations, &(&1 + missing))
    first = @buckets |> Enum.flat_map(&Map.get(groups, &1, [])) |> Enum.take(3)

    if warnings == [] and missing == 0, do: nil, else: Map.put(counts, :first, first)
  end

  def lines(nil), do: []

  def lines(summary) do
    header =
      "Dialyzer warnings: #{summary.changed} in changed files, #{summary.unchanged} in unchanged files, #{summary.unavailable_locations} with unavailable locations"

    scope =
      if summary.unknown_scope > 0,
        do: ", #{summary.unknown_scope} with change scope unavailable",
        else: ""

    guidance =
      if summary.changed > 0 and summary.unchanged > 0,
        do: [
          "Start with changed-file warnings; unchanged-file warnings may be downstream effects of a return-shape change."
        ],
        else: []

    unavailable =
      if summary.first == [],
        do: ["Warning details unavailable; inspect the complete report and raw logs."],
        else: []

    [header <> scope <> "."] ++ guidance ++ unavailable
  end

  defp warnings(result),
    do: Enum.filter(result.findings, &(&1.tool == "dialyzer" and &1.rule != "failed"))

  defp bucket(%{path: path, line: line}, _paths) when not is_binary(path) or not is_integer(line),
    do: :unavailable_locations

  defp bucket(_finding, paths) when not is_list(paths), do: :unknown_scope
  defp bucket(finding, paths), do: if(finding.path in paths, do: :changed, else: :unchanged)

  defp missing(result) do
    reported =
      result.dialyzer_summaries
      |> Enum.flat_map(fn text ->
        for [count] <- Regex.scan(~r/Total errors:\s*(\d+)/, text, capture: :all_but_first),
            do: String.to_integer(count)
      end)
      |> Enum.max(fn -> 0 end)

    max(reported - length(warnings(result)), 0)
  end
end
