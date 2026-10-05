defmodule Kogen.Checks.FeedbackTest do
  use ExUnit.Case, async: true

  alias Kogen.Checks.Feedback

  @fixtures Path.expand("../fixtures/gate_feedback", __DIR__)
  @workdir "$WORKDIR"

  test "extracts normalized failed-test ids and rejects paths outside the workdir" do
    output = """
      1) test in project (SampleTest)
         test/sample_test.exs:12

      2) test outside project (OutsideTest)
         ../outside_test.exs:4
    """

    assert Feedback.failed_test_ids(output, @workdir) == ["test/sample_test.exs:12"]
  end

  test "formats noisy Credo and Dialyzer output as deduplicated findings" do
    result = analyze("full", ["make", "check-full"], 2, "gate-full-46.log")

    assert result.exit_level == 1

    assert Enum.any?(
             result.findings,
             &(&1.tool == "credo" and &1.path == "lib/kogen/workspace/checkout.ex" and
                 &1.symbol == "Kogen.Workspace.Checkout")
           )

    assert Enum.any?(result.findings, &(&1.tool == "dialyzer" and &1.rule == "pattern_match"))
    assert result.dialyzer_summaries == ["Total errors: 1, Skipped: 0, Unnecessary Skips: 0"]
    assert Feedback.render_model_feedback([result]) =~ "[credo/FileSize]"
  end

  test "genuine test failures stay level 1 when the same run hit build-lock noise" do
    result = analyze("full", ["make", "check-full"], 2, "gate-full-51.log")

    assert result.exit_level == 1
    assert result.reason == nil

    errors = for %{severity: :error, tool: "exunit"} = finding <- result.findings, do: finding

    assert [
             %{
               rule: "assertion",
               path: "test/acceptance/bench-provided-intent_test.exs",
               line: 12
             },
             %{
               rule: "assertion",
               path: "test/acceptance/bench-provided-intent_test.exs",
               line: 26
             },
             %{rule: "failure", path: "test/harness/exchange_test.exs", line: 10}
           ] = Enum.map(errors, &Map.take(&1, [:rule, :path, :line]))

    assert [noise] =
             for(%{rule: "environment"} = finding <- result.findings, do: finding)

    assert noise.severity == :warning
    assert noise.path == "test/kernel/install_local_test.exs"
    assert noise.message =~ "environment noise"

    refute Enum.any?(result.findings, &(&1.tool == "dialyzer" and &1.severity == :error))

    feedback = Feedback.render_model_feedback([result])

    assert feedback =~
             "test/acceptance/bench-provided-intent_test.exs:12:1: error: [exunit/assertion]"

    assert feedback =~
             "test/acceptance/bench-provided-intent_test.exs:26:1: error: [exunit/assertion]"

    assert feedback =~ "test/kernel/install_local_test.exs:9:1: warning: [exunit/environment]"
    assert feedback =~ "exit 1"
    refute feedback =~ "could not check"
  end

  test "a failed run whose only failure is environment noise is still level 3" do
    [_before, noisy] =
      String.split(fixture("gate-full-51.log"), "  2) test installed launcher", parts: 2)

    [block, _rest] = String.split(noisy, "\n\n..", parts: 2)

    output =
      "  2) test installed launcher" <> block <> "\n\nResult: 298/299 passed\nFailed: 1 test\n"

    result =
      Feedback.analyze(%{
        name: "tests",
        argv: ["mix", "test"],
        exit_status: 2,
        timed_out: false,
        output: output,
        log_path: "logs/gate-full-51.log",
        workdir: @workdir
      })

    assert result.exit_level == 3
    assert result.reason == "a required tool or file was unavailable"
    assert Feedback.render_model_feedback([result]) == ""
    assert Feedback.render_environment_detail([result]) =~ "exit 3"
  end

  test "environment output with no failure location is level 3" do
    result =
      Feedback.analyze(%{
        name: "full",
        argv: ["make", "check-full"],
        exit_status: 2,
        timed_out: false,
        output: "** (File.Error) could not read file \"x\": no such file or directory\n",
        log_path: "logs/full.log",
        workdir: @workdir
      })

    assert result.exit_level == 3
    assert Feedback.render_environment_detail([result]) =~ "raw log: logs/full.log"
  end

  test "reports ExUnit assertions with location and trimmed left/right values" do
    result = analyze("tests", ["mix", "test"], 1, "gate-tests-41.log")
    feedback = Feedback.render_model_feedback([result])

    assert result.exit_level == 1

    assert feedback =~
             "test/acceptance/syn-14-bug-sla-business-hours_test.exs:7:1: error: [exunit/assertion]"

    assert feedback =~ "left: ~U[2025-04-07 12:00:00.000000Z]"
    assert feedback =~ "right: ~U[2025-04-07 12:00:00Z]"
    assert feedback =~ "Syn14BugSlaBusinessHoursAcceptanceTest"
    assert length(Regex.scan(~r/raw tail \(first failed step/, feedback)) == 1
  end

  test "classifies syntax errors from mix test as actionable compile findings" do
    result =
      Feedback.analyze(%{
        name: "tests",
        argv: ["mix", "test"],
        exit_status: 1,
        timed_out: false,
        output: "** (SyntaxError) lib/sample.ex:3:1: syntax error before: end\n",
        log_path: "logs/gate-tests.log",
        workdir: @workdir
      })

    feedback = Feedback.render_model_feedback([result])

    assert result.tool == "compile"
    assert result.exit_level == 1
    assert feedback =~ "lib/sample.ex:3:1: error: [compile/compile_error]"
    assert feedback =~ "syntax error before: end"
  end

  test "puts Dialyzer totals before file findings" do
    [_, output] = String.split(fixture("gate-full-46.log"), "Total errors:", parts: 2)

    output =
      ("Total errors:" <> output) |> String.split("make[1]: *** [dialyzer]", parts: 2) |> hd()

    result =
      Feedback.analyze(%{
        name: "dialyzer",
        argv: ["mix", "dialyzer"],
        exit_status: 2,
        timed_out: false,
        output: output,
        log_path: "logs/gate-full-46.log",
        workdir: @workdir
      })

    feedback = Feedback.render_model_feedback([result])
    [summary | _findings] = String.split(feedback, "\n")

    assert summary == "Total errors: 1, Skipped: 0, Unnecessary Skips: 0"
    assert feedback =~ "lib/kogen/engine/build/commit.ex:270:8: error: [dialyzer/pattern_match]"
  end

  test "turns mix format diffs into one finding per file and deduplicates repeats" do
    output = fixture("gate-format-42.log")

    result =
      Feedback.analyze(%{
        name: "format",
        argv: ["mix", "format", "--check-formatted"],
        exit_status: 1,
        timed_out: false,
        output: output <> output,
        log_path: "logs/gate-format-42.log",
        workdir: @workdir
      })

    paths = for %{tool: "format", path: path} <- result.findings, do: path

    assert result.exit_level == 1
    assert length(paths) == 5
    assert Enum.uniq(paths) == paths
    assert "lib/trackline/support/sla.ex" in paths
    assert Feedback.render_model_feedback([result]) =~ "[format/unformatted]"
  end

  test "caps findings per tool and includes only the first failed step tail" do
    paths = Enum.map_join(1..12, "\n", &"lib/sample_#{&1}.ex")
    format_output = "mix format failed, but no files were formatted\n" <> paths

    format =
      Feedback.analyze(%{
        name: "format",
        argv: ["mix", "format", "--check-formatted"],
        exit_status: 1,
        timed_out: false,
        output: format_output,
        log_path: "logs/format.log",
        workdir: @workdir
      })

    tests = analyze("tests", ["mix", "test"], 1, "gate-tests-41.log")
    feedback = Feedback.render_model_feedback([tests, format])

    assert length(Regex.scan(~r/\[format\/unformatted\]/, feedback)) == 10
    assert feedback =~ "… 2 more format findings"
    assert length(Regex.scan(~r/raw tail \(first failed step/, feedback)) == 1
    assert feedback =~ "raw tail (first failed step tests):"
    refute feedback =~ "raw tail (first failed step format):"
  end

  test "anchors compiler warnings to source location and known function symbol" do
    result =
      analyze(
        "compile",
        ["mise", "exec", "--", "mix", "compile", "--warnings-as-errors"],
        1,
        "compile-35.log"
      )

    feedback = Feedback.render_model_feedback([result])

    assert result.exit_level == 1
    assert feedback =~ "lib/kogen/engine/build/commit.ex:19:42: error: [compile/undefined]"
    assert feedback =~ "Kogen.Engine.Build.Commit.run/1"
    assert feedback =~ "undefined function prepare_candidate/4"
    assert feedback =~ "Kogen.Engine.Build.Commit.same_tree/2"
    assert feedback =~ "raw log: logs/compile-35.log"
  end

  test "classifies clean, usage, and unavailable checks with distinct exit levels" do
    clean =
      Feedback.analyze(%{
        name: "tests",
        argv: ["mix", "test"],
        exit_status: 0,
        timed_out: false,
        output: "Result: 4 passed\n",
        log_path: nil,
        workdir: @workdir
      })

    usage =
      Feedback.analyze(%{
        name: "format",
        argv: ["mix", "format"],
        exit_status: 2,
        timed_out: false,
        output: "** (Mix) Unknown option --misspelled.\n",
        log_path: nil,
        workdir: @workdir
      })

    unavailable =
      Feedback.analyze(%{
        name: "tests",
        argv: ["mix", "test"],
        exit_status: nil,
        timed_out: false,
        output: "mix: command not found\n",
        log_path: nil,
        workdir: @workdir
      })

    swallowed_environment_error =
      Feedback.analyze(%{
        name: "tests",
        argv: ["mix", "test"],
        exit_status: 0,
        timed_out: false,
        output: "mix: command not found\n",
        log_path: nil,
        workdir: @workdir
      })

    assert clean.exit_level == 0
    assert usage.exit_level == 2
    assert Feedback.render_model_feedback([usage]) =~ "exit 2"
    assert unavailable.exit_level == 3
    assert Feedback.render_model_feedback([unavailable]) == ""
    assert swallowed_environment_error.exit_level == 3
    assert Feedback.render_model_feedback([swallowed_environment_error]) == ""

    excused_test_flake =
      Feedback.analyze(%{
        name: "tests",
        argv: ["mix", "test"],
        exit_status: 0,
        timed_out: false,
        output: fixture("gate-tests-41.log"),
        log_path: nil,
        workdir: @workdir
      })

    assert excused_test_flake.exit_level == 0
    assert Feedback.render_model_feedback([excused_test_flake]) == ""
  end

  test "ignores lock and progress noise from a clean benchmark test run" do
    result =
      Feedback.analyze(%{
        name: "tests",
        argv: ["mix", "test"],
        exit_status: 0,
        timed_out: false,
        output: fixture("gate-benchmark-tests.log"),
        log_path: nil,
        workdir: @workdir
      })

    assert result.exit_level == 0
    assert result.findings == []
    assert Feedback.render_model_feedback([result]) == ""
  end

  test "reduces feedback across five noisy red gate logs" do
    gates = [
      {"check-full", ["make", "check-full"], 2, "gate-full-46.log"},
      {"check-full", ["make", "check-full"], 2, "gate-full-97.log"},
      {"check-full", ["make", "check-full"], 2, "gate-full-59.log"},
      {"check-full", ["make", "check-full"], 2, "gate-full-49.log"},
      {"format-42", ["mix", "format", "--check-formatted"], 1, "gate-format-42.log"}
    ]

    {before, compact_chars} =
      Enum.reduce(gates, {0, 0}, fn {name, argv, status, file}, {before, compact_chars} ->
        output = file |> fixture() |> gate_tail()

        result =
          Feedback.analyze(%{
            name: name,
            argv: argv,
            exit_status: status,
            timed_out: false,
            output: output,
            log_path: "logs/#{file}",
            workdir: @workdir
          })

        old_feedback = "#{name} exited #{status}.\n#{output}"
        compact = Feedback.render_model_feedback([result])

        assert result.exit_level in [1, 3]
        assert String.length(compact) < String.length(old_feedback)
        {before + String.length(old_feedback), compact_chars + String.length(compact)}
      end)

    # Assertion source and values now stay in each finding, within its own size budget.
    assert compact_chars < before * 0.35
  end

  defp analyze(name, argv, status, file) do
    Feedback.analyze(%{
      name: name,
      argv: argv,
      exit_status: status,
      timed_out: false,
      output: fixture(file),
      log_path: "logs/#{file}",
      workdir: @workdir
    })
  end

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp gate_tail(output) do
    if String.length(output) > 10_000,
      do: String.slice(output, String.length(output) - 10_000, 10_000),
      else: output
  end
end
