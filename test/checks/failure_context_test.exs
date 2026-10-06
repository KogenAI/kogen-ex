defmodule Kogen.Checks.FailureContextTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Checks.Feedback
  alias Kogen.Contracts.CheckOutput

  test "the finding retains the test, assertion, multiline error and values, and first project frame",
       %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "lib/cart.ex")

    output = """
      1) test calculates the cart total (CartTest)
         test/cart_test.exs:12
         Assertion with == failed
         totals differ after applying the discount
         expected the rounded total
         code:  assert Cart.total(cart) == 42
         left:  %{total: 41,
                  items: [:first, :second]}
         right: %{total: 42, items: [:first, :second]}
         stacktrace:
           (ex_unit 1.20.4) lib/ex_unit/assertions.ex:101: ExUnit.Assertions.assert/2
           deps/money/lib/money.ex:33: Money.round/1
           test/cart_test.exs:13: (test)
           lib/cart.ex:24: Cart.total/1
           lib/cart.ex:88: Cart.sum/1
    """

    result = analyze(output, tmp_dir)
    assert [finding] = result.findings
    assert finding.path == "test/cart_test.exs"
    assert finding.line == 12
    feedback = Feedback.render_model_feedback([result])
    assert feedback =~ "CartTest \"calculates the cart total\""
    assert feedback =~ "test/cart_test.exs:12:1"

    assert finding.message =~
             "totals differ after applying the discount\nexpected the rounded total"

    assert finding.message =~ "code: assert Cart.total(cart) == 42"
    assert finding.message =~ "left: %{total: 41,\nitems: [:first, :second]}"
    assert finding.message =~ "right: %{total: 42, items: [:first, :second]}"
    assert finding.message =~ "project: lib/cart.ex:24"
    refute finding.message =~ "lib/cart.ex:88"
    refute finding.message =~ "assertions.ex"
    refute finding.message =~ "money.ex"
    assert String.length(finding.message) < 600
  end

  test "twenty error lines fit, while later lines are omitted", %{tmp_dir: tmp_dir} do
    error = ["** (RuntimeError) detail" | Enum.map(2..22, &"detail-#{&1}")]

    output =
      "  1) test raises (CartTest)\n     test/cart_test.exs:12\n" <>
        Enum.map_join(error, "\n", &"     #{&1}") <>
        "\n     stacktrace:\n     test/cart_test.exs:13: (test)\n"

    assert [finding] = analyze(output, tmp_dir).findings
    assert finding.message =~ "detail-20"
    refute finding.message =~ "detail-21"
    refute finding.message =~ "detail-22"
  end

  test "long values are capped at 400 characters and share a detail budget below 600", %{
    tmp_dir: tmp_dir
  } do
    left = String.duplicate("L", 1_000)
    right = String.duplicate("R", 1_000)
    output = assertion(left, "nil")
    assert [finding] = analyze(output, tmp_dir).findings

    value =
      finding.message
      |> String.split("left: ", parts: 2)
      |> List.last()
      |> String.split("\n")
      |> hd()

    assert String.length(value) == 400
    assert String.ends_with?(value, "…")
    assert String.length(finding.message) < 600

    assert [both] = analyze(assertion(left, right), tmp_dir).findings
    assert both.message =~ "left: L"
    assert both.message =~ "right: R"
    assert both.message =~ "code: assert Cart.total(cart) == nil"
    assert String.length(both.message) < 600
  end

  test "red feedback lists at most thirty ranges and green feedback omits them", %{
    tmp_dir: tmp_dir
  } do
    result = analyze(assertion("41", "42"), tmp_dir)
    ranges = Enum.map(1..35, &"file-#{&1}.ex: base 2 -> candidate 2-3")
    callback = fn -> {:ok, ranges} end
    feedback = Feedback.render_model_feedback([result], callback)
    [_, changed] = String.split(feedback, "Candidate changes relative to Build base:\n", parts: 2)
    assert length(String.split(changed, "\n")) == 30
    assert changed =~ "file-30.ex: base 2 -> candidate 2-3"
    refute changed =~ "file-31.ex"

    green =
      Feedback.analyze(%CheckOutput{
        name: "tests",
        argv: ["mix", "test"],
        exit_status: 0,
        timed_out: false,
        output: "1 test, 0 failures",
        log_path: nil,
        workdir: tmp_dir
      })

    assert Feedback.render_model_feedback([green], callback) == ""
  end

  defp assertion(left, right) do
    "  1) test totals (CartTest)\n     test/cart_test.exs:12\n     Assertion with == failed\n" <>
      "     code: assert Cart.total(cart) == nil\n     left: #{left}\n     right: #{right}\n"
  end

  defp analyze(output, workdir) do
    Feedback.analyze(%CheckOutput{
      name: "tests",
      argv: ["mix", "test"],
      exit_status: 1,
      timed_out: false,
      output: output,
      log_path: "logs/tests.log",
      workdir: workdir
    })
  end

  defp write_source(root, path) do
    File.mkdir_p!(Path.dirname(Path.join(root, path)))
    File.write!(Path.join(root, path), "defmodule Cart do\nend\n")
  end
end
