defmodule Kogen.Quality.Report do
  @moduledoc false

  alias Kogen.Contracts.Finding

  @spec finding(String.t(), String.t(), String.t() | nil, integer() | nil, String.t(), atom()) ::
          Finding.t()
  def finding(tool, rule, path, line, message, severity \\ :warning) do
    %Finding{
      tool: tool,
      rule: rule,
      path: path,
      line: line,
      col: 1,
      symbol: nil,
      severity: severity,
      message: message
    }
  end

  @spec command(String.t(), [Finding.t()]) :: map()
  def command(tool, findings) do
    findings = Enum.sort_by(findings, &{&1.path, &1.line, &1.rule, &1.message})
    level = if Enum.any?(findings, &(&1.severity == :error)), do: 1, else: 0
    lines = Enum.map(findings, &render/1)

    %{
      advisory?: level == 0,
      name: tool,
      tool: tool,
      argv: ["mix", tool],
      exit_status: level,
      exit_level: level,
      timed_out: false,
      log_path: nil,
      reason: nil,
      base_red?: false,
      findings: findings,
      dialyzer_summaries: [],
      output: Enum.join(lines, "\n"),
      warnings:
        for({finding, line} <- Enum.zip(findings, lines), finding.severity != :error, do: line)
    }
  end

  @spec skip(String.t(), term()) :: map()
  def skip(tool, reason) do
    command(tool, [finding(tool, "skipped", nil, nil, "Skipped: #{reason}.", :note)])
  end

  defp render(finding) do
    location = if finding.path, do: "#{finding.path}:#{finding.line}:1: ", else: ""
    "#{location}#{finding.severity}: [#{finding.tool}/#{finding.rule}] #{finding.message}"
  end
end
