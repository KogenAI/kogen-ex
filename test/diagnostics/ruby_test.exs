defmodule Kogen.Diagnostics.RubyTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.CheckOutput
  alias Kogen.Checks.Feedback

  test "Rails failures retain test identities so new failures are not excused by a red base", %{
    tmp_dir: root
  } do
    old = analyze(root, "A1", 1)
    baseline = CheckBaseline.from_assessments([old])

    assert [%{tool: "minitest", path: "test/greeting_test.rb", symbol: "GreetingTest#test_A1"}] =
             old.findings

    assert CheckBaseline.annotate(old, baseline).base_red?
    refute CheckBaseline.annotate(analyze(root, "A2", 1), baseline).base_red?
    assert analyze(root, "A1", 0).exit_level == 0
  end

  test "a Rails check that collects no tests does not pass", %{tmp_dir: root} do
    result =
      Feedback.analyze(%CheckOutput{
        name: "tests",
        argv: ["bundle", "exec", "rails", "test"],
        exit_status: 0,
        timed_out: false,
        output: "0 runs, 0 assertions, 0 failures, 0 errors, 0 skips",
        log_path: nil,
        workdir: root
      })

    assert result.exit_level == 3
    assert result.reason == "the check collected no test results"
  end

  defp analyze(root, id, status) do
    Feedback.analyze(%CheckOutput{
      name: "tests",
      argv: ["bundle", "exec", "rails", "test"],
      exit_status: status,
      timed_out: false,
      log_path: nil,
      workdir: root,
      output:
        "Failure:\nGreetingTest#test_#{id} [test/greeting_test.rb:5]:\nExpected new, got old.\n\nbin/rails test test/greeting_test.rb:3\n1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
    })
  end
end
