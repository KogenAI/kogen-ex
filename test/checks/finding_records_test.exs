defmodule Kogen.Checks.FindingRecordsTest do
  use Kogen.Testkit.Case

  alias Kogen.Checks.Feedback

  test "adapters retain meanings and stable identities when lines move", %{tmp_dir: root} do
    cases = [
      {"compile",
       "warning: function unused/0 is unused\n  lib/sample.ex:12: Sample (module)\nHint: remove the unused function\n",
       :warning, "Sample.unused/0"},
      {"credo",
       "[W] Credo.Check.Warning.UnusedOperation: use the result\nlib/sample.ex:12:2 #(Sample.run/0)\n",
       :warning, "Sample.run/0"},
      {"dialyzer",
       "lib/sample.ex:12:pattern_match\nThe pattern can never match.\n\nPattern:\n{:ok, value}\nType:\n{:error, reason}\nHint: correct the decoder return shape\n________________________________________________________________________________\n",
       :error, nil},
      {"test",
       "1) test returns tuple (SampleTest)\n test/sample_test.exs:12\n Assertion with == failed\n left: {:error, :bad}\n right: {:ok, :good}\n",
       :error, ~s(SampleTest "returns tuple")},
      {"format", "mix format failed\nlib/sample.ex\n", :error, nil}
    ]

    for {task, output, severity, symbol} <- cases do
      result = analyze(task, output, root)
      assert [finding] = result.findings
      assert finding.severity == severity
      assert finding.symbol == symbol
      assert is_binary(finding.id)
      assert finding.tool != ""
      assert finding.message != ""
      assert finding.path
      assert [moved] = analyze(task, String.replace(output, ":12", ":42"), root).findings
      assert finding.id == moved.id
      {:ok, report} = Feedback.write_report([result], root)

      assert [%{"id" => id, "message" => message, "severity" => level}] =
               Jason.decode!(File.read!(report))["findings"]

      assert id == finding.id
      assert message == finding.message
      assert level == Atom.to_string(severity)

      assert [result] |> Feedback.render_model_feedback() |> String.split("\n") |> List.last() =~
               "gate:"
    end
  end

  test "full explanations and hints survive program reports while text stays compact", %{
    tmp_dir: root
  } do
    detail = String.duplicate("long type explanation ", 100)

    output =
      "lib/sample.ex:12:3:pattern_match\nThe return tuple cannot match.\n\n#{detail}\nHint: change decoder return type\n________________________________________________________________________________\n"

    result = analyze("dialyzer", output, root)
    assert [finding] = result.findings
    assert finding.explanation =~ String.trim(detail)
    assert finding.hint == "change decoder return type"
    assert Feedback.render_model_feedback([result]) =~ "Hint: change decoder return type"
    {:ok, report} = Feedback.write_report([result], root)
    assert [%{"explanation" => explanation}] = Jason.decode!(File.read!(report))["findings"]
    assert explanation =~ String.trim(detail)
  end

  test "different tools and tests stay distinct, including long test names", %{tmp_dir: root} do
    tests =
      for suffix <- ["first", "second"] do
        "1) test #{String.duplicate("same prefix ", 12)}#{suffix} (SampleTest)\n test/sample_test.exs:12\n Assertion failed\n"
      end

    result = analyze("test", Enum.join(tests, "\n"), root)
    assert [first, second] = result.findings
    assert first.id != second.id
    assert first.symbol =~ "first"
    assert second.symbol =~ "second"
    compile = analyze("compile", "lib/sample.ex:12:3: error: unused value", root)
    dialyzer = analyze("dialyzer", "lib/sample.ex:12:3:unused\nunused value\n", root)
    assert [a] = compile.findings
    assert [b] = dialyzer.findings
    assert a.id != b.id
  end

  test "unknown positions stay unknown and complete logs are parsed before clipping", %{
    tmp_dir: root
  } do
    log = Path.join(root, "full.log")

    output =
      "lib/first.ex:2:pattern_match\nWrong tuple.\n" <>
        String.duplicate("\n", 12_000) <> "lib/last.ex:33:pattern_match\nDownstream tuple.\n"

    File.write!(log, output)

    result =
      Feedback.analyze(%{
        name: "dialyzer",
        argv: ["mix", "dialyzer"],
        exit_status: 1,
        timed_out: false,
        output: "only the tail",
        log_path: log,
        workdir: root
      })

    assert Enum.map(result.findings, & &1.path) == ["lib/first.ex", "lib/last.ex"]
    assert Enum.all?(result.findings, &is_nil(&1.col))
    assert Feedback.render_model_feedback([result]) =~ "lib/first.ex:2: error:"
    assert [format] = analyze("format", "mix format failed\nlib/sample.ex\n", root).findings
    assert format.line == nil
    assert format.col == nil
  end

  test "a compiler warning without a source location is retained honestly", %{tmp_dir: root} do
    assert [finding] =
             analyze("compile", "warning: unused result\nHint: use the returned value\n", root).findings

    assert finding.path == nil
    assert finding.line == nil
    assert finding.col == nil
    assert finding.severity == :warning
    assert finding.hint == "use the returned value"

    assert Feedback.render_model_feedback([analyze("compile", "warning: unused result\n", root)]) =~
             "location unavailable"
  end

  defp analyze(task, output, workdir) do
    Feedback.analyze(%{
      name: task,
      argv: ["mix", task],
      exit_status: 1,
      timed_out: false,
      output: output,
      log_path: nil,
      workdir: workdir
    })
  end
end
