defmodule Kogen.Contracts.CheckBaseline do
  @moduledoc false

  @warning_findings 5

  @spec from_assessments([map()]) :: [map()]
  def from_assessments(assessments) do
    Enum.map(assessments, fn assessment ->
      status = if assessment.exit_level == 0, do: :green, else: :red

      findings =
        if status == :red,
          do: Enum.map(assessment.findings, &compact_finding/1),
          else: []

      %{name: assessment.name, status: status, findings: findings}
    end)
  end

  @spec annotate(map(), [map()]) :: map()
  def annotate(%{name: name, exit_level: level, findings: findings} = assessment, baseline) do
    base_red? = level in [1, 2] and matches?(baseline, name, findings)
    Map.put(assessment, :base_red?, base_red?)
  end

  @spec matches?([map()], String.t(), [map()]) :: boolean()
  def matches?(baseline, name, findings) do
    case Enum.find(baseline, &(&1.name == name and &1.status == :red)) do
      %{findings: base_findings} -> subset?(findings, base_findings)
      _missing -> false
    end
  end

  @spec warning(map()) :: [String.t()]
  def warning(%{base_red?: true, name: name, findings: findings}) do
    details =
      findings
      |> Enum.take(@warning_findings)
      |> Enum.map_join("\n", &finding_text/1)

    [
      "Base-red warning: check \"#{name}\" still has only findings recorded at approval." <>
        details
    ]
  end

  def warning(_assessment), do: []

  @spec approval_warning([map()]) :: String.t()
  def approval_warning(baseline) do
    red = Enum.filter(baseline, &(&1.status == :red))

    case red do
      [] ->
        ""

      checks ->
        rows = Enum.map_join(checks, "", &approval_check_line/1)

        "Warning: configured checks are already red on the base:\n" <>
          rows <>
          "Hint: fix the base first, or scope the check, e.g. a changed-files format argv.\n"
    end
  end

  defp approval_check_line(%{name: name, findings: findings}) do
    details =
      findings
      |> Enum.take(@warning_findings)
      |> Enum.map_join("; ", &finding_label/1)

    "  - #{name}: #{if(details == "", do: "failed without parseable findings", else: details)}\n"
  end

  defp subset?(findings, base_findings) when findings != [] do
    current = Enum.map(findings, &identity/1)
    base = base_findings |> Enum.map(&identity/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

    Enum.all?(current, fn
      nil -> false
      identity -> MapSet.member?(base, identity)
    end)
  end

  defp subset?(_findings, _base_findings), do: false

  defp compact_finding(finding) do
    {kind, id} =
      if finding.tool == "exunit",
        do: {:test, finding.symbol || finding.rule},
        else: {:rule, finding.rule}

    %{
      path: finding.path,
      kind: kind,
      id: id,
      tool: finding.tool,
      message: finding.message
    }
  end

  defp identity(%{path: path, kind: :test, id: id}) when is_binary(path) and is_binary(id),
    do: {path, :test, id}

  defp identity(%{path: path, kind: :rule, id: id}) when is_binary(path) and is_binary(id),
    do: {path, :rule, id}

  defp identity(%{path: path, tool: "exunit", symbol: symbol})
       when is_binary(path) and is_binary(symbol), do: {path, :test, symbol}

  defp identity(%{path: path, rule: rule}) when is_binary(path) and is_binary(rule),
    do: {path, :rule, rule}

  defp identity(_finding), do: nil

  defp finding_text(finding), do: "\n  - " <> finding_label(compact_finding(finding))

  defp finding_label(%{path: path, kind: kind, id: id, message: message}) do
    location = if is_binary(path), do: path <> " ", else: ""
    "#{location}[#{kind}/#{id}] #{message}"
  end
end
