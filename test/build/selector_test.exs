defmodule Kogen.Build.SelectorTest do
  use Kogen.Testkit.Case

  alias Kogen.Build.Demotion
  alias Kogen.Build.GateSummary
  alias Kogen.Build.Selector
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project

  @acceptance "test/acceptance/slug_test.exs"

  test "ranks green first, then fewer failing acceptance items, tests, and diff lines" do
    candidates = [
      red(:a, %{checks_green: false, failing_acceptance: 0, failing_tests: 1, diff_lines: 1}),
      red(:b, %{checks_green: true, failing_acceptance: 2, failing_tests: 2, diff_lines: 5}),
      red(:c, %{checks_green: true, failing_acceptance: 1, failing_tests: 3, diff_lines: 9}),
      red(:d, %{checks_green: true, failing_acceptance: 1, failing_tests: 2, diff_lines: 9}),
      red(:e, %{checks_green: true, failing_acceptance: 1, failing_tests: 2, diff_lines: 3}),
      %{id: :f, status: :green, metrics: %{diff_lines: 50}},
      %{id: :g, status: :green, metrics: %{diff_lines: 20}},
      red(:h, %{})
    ]

    assert Enum.map(Selector.rank(candidates), & &1.id) == [:g, :f, :e, :d, :c, :b, :a, :h]
    assert Selector.best(candidates).id == :g
    assert Selector.best([red(:x, %{}), red(:y, %{})]).id == :x
  end

  test "gate metrics separate acceptance-only failures from other red checks" do
    acceptance_only = gate([test_check([finding(@acceptance, "A1"), finding(@acceptance, "A2")])])

    assert %{
             acceptance_only: true,
             checks_green: true,
             failing_acceptance: 2,
             failing_tests: 2,
             failure_count: 2
           } = GateSummary.metrics(acceptance_only, @acceptance)

    mixed = gate([test_check([finding(@acceptance, "A1"), finding("test/other_test.exs", "x")])])

    assert %{acceptance_only: false, checks_green: false} =
             GateSummary.metrics(mixed, @acceptance)

    format = %{name: "format", tool: "format", exit_level: 1, findings: []}
    with_format = gate([test_check([finding(@acceptance, "A1")]), format])

    assert %{acceptance_only: false, failure_count: 2} =
             GateSummary.metrics(with_format, @acceptance)

    base_red = Map.put(format, :base_red?, true)

    assert %{acceptance_only: true} =
             GateSummary.metrics(
               gate([test_check([finding(@acceptance, "A1")]), base_red]),
               @acceptance
             )

    assert %{checks_green: true, failure_count: 0} = GateSummary.metrics(gate([]), @acceptance)
    assert %{checks_green: false, failure_count: nil} = GateSummary.metrics(nil, @acceptance)
  end

  test "demotion excludes tagged tests from mix test checks only" do
    project = %Project{
      root: "/tmp/p",
      name: "p",
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{},
      checks: [
        %CheckSpec{
          name: "tests",
          argv: ["python3", "timer", "--", "mise", "exec", "--", "mix", "test"],
          timeout_ms: 1
        },
        %CheckSpec{name: "format", argv: ["mix", "format", "--check-formatted"], timeout_ms: 1}
      ]
    }

    [tests, format] = Demotion.exclude(project, "slug", ["A2", "A3"]).checks

    assert tests.argv ==
             ["python3", "timer", "--", "mise", "exec", "--", "mix", "test"] ++
               ["--exclude", "intent:slug/A2", "--exclude", "intent:slug/A3"]

    assert format.argv == ["mix", "format", "--check-formatted"]
    assert Demotion.exclude(project, "slug", []) == project
  end

  test "demoted ledger failures no longer count, including the suite exit" do
    assert Demotion.remaining(["A2", "suite"], ["A2"]) == []
    assert Demotion.remaining(["A1", "A2", "suite"], ["A2"]) == ["A1", "suite"]
    assert Demotion.remaining(["A1"], []) == ["A1"]
    assert Demotion.remaining(["suite"], ["A2"]) == ["suite"]
  end

  defp red(id, metrics), do: %{id: id, status: :failed, metrics: metrics}

  defp gate(checks), do: %{fixes: [], checks: checks, failed_test_count: nil}

  defp test_check(findings),
    do: %{name: "tests", tool: "exunit", exit_level: 1, findings: findings}

  defp finding(path, symbol), do: %{tool: "exunit", path: path, line: 1, symbol: symbol}
end
