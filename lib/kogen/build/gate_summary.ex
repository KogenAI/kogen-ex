defmodule Kogen.Build.GateSummary do
  @moduledoc "Compact, JSON-ready summaries of one done-gate result."

  alias Kogen.Build.GateMetrics

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
      warnings: Map.get(gate, :warnings, []),
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

  @doc """
  Selector inputs from one raw gate. `acceptance_only` means every red command failed only
  on tests in `acceptance_path`; `checks_green` adds a fully green gate. `failure_count` is
  the progress measure for repairs: failing tests (or findings) plus red commands without any.
  """
  @spec metrics(map() | nil, String.t()) :: GateMetrics.t()
  def metrics(nil, _acceptance_path), do: %GateMetrics{}

  def metrics(gate, acceptance_path) when is_map(gate) do
    red =
      Enum.filter(
        Map.get(gate, :fixes, []) ++ Map.get(gate, :checks, []),
        &(red?(&1) and not Map.get(&1, :base_red?, false))
      )

    findings =
      red
      |> Enum.flat_map(fn command ->
        Enum.map(Map.get(command, :findings, []), &{command, &1})
      end)
      |> Enum.uniq_by(fn {command, finding} -> {Map.get(command, :name), identity(finding)} end)
      |> Enum.map(&elem(&1, 1))

    acceptance = Enum.filter(findings, &(Map.get(&1, :path) == acceptance_path))
    silent = Enum.count(red, &(Map.get(&1, :findings, []) == []))

    only =
      red != [] and silent == 0 and Enum.all?(red, &(Map.get(&1, :tool) == "exunit")) and
        length(acceptance) == length(findings)

    tests = Map.get(gate, :failed_test_count) || length(findings)

    %GateMetrics{
      checks_green: red == [] or only,
      acceptance_only: only,
      failing_acceptance: length(acceptance),
      failing_tests: tests,
      failure_count: tests + silent
    }
  end

  defp red?(command), do: is_integer(Map.get(command, :exit_level)) and command.exit_level > 0

  defp identity(finding) do
    Map.get(finding, :symbol) ||
      {Map.get(finding, :path), Map.get(finding, :line), Map.get(finding, :message)}
  end

  defp command(command, kind) do
    summary = %{
      kind: if(Map.get(command, :advisory?, false), do: :advisory, else: kind),
      name: Map.get(command, :name),
      exit_level: Map.get(command, :exit_level),
      exit_status: Map.get(command, :exit_status),
      timed_out: Map.get(command, :timed_out),
      base_red: Map.get(command, :base_red?, false)
    }

    {summary, Map.get(command, :findings, [])}
  end

  defp command_findings({%{base_red: true}, _findings}), do: []

  defp command_findings({%{exit_level: level, name: name}, findings}) when level >= 0 do
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
