defmodule Kogen.Build.FindingReportTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.GateSummary
  alias Kogen.Contracts.Finding

  test "program gate summary retains full record meaning and links the complete report" do
    explanation = String.duplicate("return shape detail ", 100)

    finding =
      Finding.record(%{
        tool: "dialyzer",
        rule: "pattern_match",
        path: "lib/origin.ex",
        line: 20,
        col: 3,
        symbol: "Origin.decode/1",
        severity: :error,
        message: "wrong return shape",
        explanation: explanation,
        hint: "correct the decoder"
      })

    summary =
      GateSummary.compact(%{
        checks: [%{name: "full", exit_level: 1, findings: [finding]}],
        findings_path: "/run/gate-findings.json",
        dialyzer_summary: %{
          changed: 1,
          unchanged: 0,
          unavailable_locations: 0,
          unknown_scope: 0,
          first: [finding]
        }
      })

    json = summary |> Jason.encode!() |> Jason.decode!()

    assert [
             %{
               "id" => id,
               "col" => 3,
               "explanation" => ^explanation,
               "hint" => "correct the decoder",
               "message" => "wrong return shape"
             }
           ] = json["findings"]

    assert id == finding.id
    assert json["findings_path"] == "/run/gate-findings.json"
    assert json["dialyzer_summary"]["changed"] == 1
    assert hd(json["dialyzer_summary"]["first"])["id"] == finding.id
  end
end
