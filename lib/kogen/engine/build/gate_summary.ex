defmodule Kogen.Engine.Build.GateSummary do
  @moduledoc false

  @max_findings 20
  @message_limit 240

  @spec compact(map() | nil) :: map() | nil
  def compact(nil), do: nil

  def compact(gate) when is_map(gate) do
    commands =
      Enum.map(Map.get(gate, :fixes, []), &command(&1, :fix)) ++
        Enum.map(Map.get(gate, :checks, []), &command(&1, :check))

    findings = Enum.flat_map(commands, &command_findings/1)

    %{
      status: Map.get(gate, :status),
      failed_test_count: Map.get(gate, :failed_test_count),
      checks: Enum.map(commands, &elem(&1, 0)),
      finding_count: length(findings),
      findings: Enum.take(findings, @max_findings)
    }
  end

  @spec done_gate(map() | nil, atom(), non_neg_integer() | nil) :: map()
  def done_gate(gate, outcome, failed_test_count) do
    %{
      outcome: outcome,
      failed_test_count: failed_test_count,
      findings: Map.get(gate || %{}, :failures, []),
      gate_summary: compact(gate)
    }
  end

  defp command(command, kind) do
    summary = %{
      kind: kind,
      name: Map.get(command, :name),
      exit_level: Map.get(command, :exit_level),
      exit_status: Map.get(command, :exit_status),
      timed_out: Map.get(command, :timed_out)
    }

    {summary, Map.get(command, :findings, [])}
  end

  defp command_findings({%{exit_level: level, name: name}, findings}) when level > 0 do
    Enum.map(findings, &finding(name, &1))
  end

  defp command_findings(_command), do: []

  defp finding(check, finding) do
    path = Map.get(finding, :path)
    line = Map.get(finding, :line)

    %{
      check: check,
      tool: Map.get(finding, :tool),
      rule: Map.get(finding, :rule),
      severity: Map.get(finding, :severity),
      path: path,
      line: line,
      location: location(path, line),
      symbol: Map.get(finding, :symbol),
      message: short_message(Map.get(finding, :message))
    }
  end

  defp location(path, line) when is_binary(path) and is_integer(line), do: "#{path}:#{line}"
  defp location(_path, _line), do: nil

  defp short_message(message) when is_binary(message) do
    message = message |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(message) > @message_limit do
      String.slice(message, 0, @message_limit - 3) <> "..."
    else
      message
    end
  end

  defp short_message(_message), do: nil
end
