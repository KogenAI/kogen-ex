defmodule Kogen.Contracts.CheckBaselineTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.CheckBaseline

  test "a check unparseable or unavailable on the base is excused while it stays opaque" do
    unparseable = %{tool: "check", rule: "failed", path: nil, message: "x"}

    baseline =
      CheckBaseline.from_assessments([
        %{name: "lint", exit_level: 1, findings: []},
        %{name: "tool", exit_level: 3, findings: [unparseable]}
      ])

    finding = %{tool: "credo", rule: "R", path: "lib/new.ex", symbol: nil}

    assert %{base_red?: true} =
             CheckBaseline.annotate(
               %{name: "lint", exit_level: 1, findings: [unparseable]},
               baseline
             )

    assert %{base_red?: true} =
             CheckBaseline.annotate(%{name: "tool", exit_level: 3, findings: []}, baseline)

    assert %{base_red?: false} =
             CheckBaseline.annotate(%{name: "lint", exit_level: 1, findings: [finding]}, baseline)

    assert %{base_red?: false} =
             CheckBaseline.annotate(%{name: "other", exit_level: 1, findings: []}, baseline)
  end

  test "a check with parseable base findings is excused only for a subset of them" do
    old = %{tool: "format", rule: "unformatted", path: "lib/old.ex", symbol: nil, message: "m"}
    baseline = CheckBaseline.from_assessments([%{name: "format", exit_level: 1, findings: [old]}])
    new = %{old | path: "lib/new.ex"}

    assert %{base_red?: true} =
             CheckBaseline.annotate(%{name: "format", exit_level: 1, findings: [old]}, baseline)

    assert %{base_red?: false} =
             CheckBaseline.annotate(
               %{name: "format", exit_level: 1, findings: [old, new]},
               baseline
             )

    assert %{base_red?: false} =
             CheckBaseline.annotate(%{name: "format", exit_level: 3, findings: []}, baseline)
  end

  test "a matching rule from another tool is not the same finding" do
    finding = %{
      tool: "credo",
      rule: "unused",
      path: "lib/sample.ex",
      symbol: nil,
      message: "unused value"
    }

    baseline =
      CheckBaseline.from_assessments([%{name: "full", exit_level: 1, findings: [finding]}])

    other = %{finding | tool: "compile"}

    assert %{base_red?: false} =
             CheckBaseline.annotate(%{name: "full", exit_level: 1, findings: [other]}, baseline)
  end
end
