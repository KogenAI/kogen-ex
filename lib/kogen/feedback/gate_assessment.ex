defmodule Kogen.Feedback.GateAssessment do
  @moduledoc false

  alias Kogen.Contracts.CommandExit

  def gate(result, spec, paths) do
    findings = command_findings(result, spec) ++ tree_findings(paths)

    if findings == [] or (result.exit_level == 0 and paths == []) do
      result
    else
      %{result | findings: findings, exit_level: 1, reason: nil}
    end
  end

  defp command_findings(%{timed_out: true}, spec),
    do: [finding("timeout", spec.name, "timed out after #{seconds(spec.timeout_ms)} s")]

  defp command_findings(result, spec) do
    cond do
      CommandExit.tool_missing?(result.exit_status) or missing?(result) ->
        [
          finding(
            "unavailable",
            spec.name,
            "#{hd(spec.argv)} is not available, but it ran on the base"
          )
        ]

      result.exit_level == 3 ->
        [finding("unavailable", spec.name, result.reason || "command could not run")]

      String.starts_with?(spec.name, "fix/") and result.exit_status != 0 ->
        [
          finding(
            "exit_#{inspect(result.exit_status)}",
            spec.name,
            "#{spec.name} exited #{inspect(result.exit_status)}"
          )
        ]

      true ->
        result.findings
    end
  end

  defp seconds(ms) when rem(ms, 1_000) == 0, do: div(ms, 1_000)
  defp seconds(ms), do: ms / 1_000

  defp missing?(result),
    do: String.contains?(result.output, ["command not found", "Command was not found"])

  defp tree_findings(paths),
    do: Enum.map(paths, &finding("tree_mutated", &1, "check changed the verified tree: #{&1}"))

  defp finding(rule, path, message) do
    %{
      tool: "check",
      rule: rule,
      severity: :error,
      path: path,
      line: nil,
      col: nil,
      symbol: nil,
      message: message
    }
  end
end
