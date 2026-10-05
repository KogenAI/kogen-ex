defmodule Kogen.Runner.EdgeTestsTest do
  use Kogen.Testkit.Case

  alias Kogen.Runner.EdgeTests

  test "at most 20 edge tests run; later ones are tagged out of the run" do
    tests = Enum.map_join(1..23, "\n", &"  test \"case #{&1}\" do\n    assert true\n  end")
    reply = "Here:\n```elixir\ndefmodule KogenEdge.ManyTest do\n#{tests}\nend\n```\n"

    assert {:ok, %{generated: 20, names: names, source: source}} = EdgeTests.parse(reply)
    assert names == Enum.map(1..20, &"case #{&1}")
    assert length(Regex.scan(~r/@tag :kogen_edge_extra\n  test "case 2[123]"/, source)) == 3
    assert EdgeTests.run_arguments() == ["--exclude", "kogen_edge_extra"]

    assert EdgeTests.parse("No tests today.") == {:error, :no_test_module}
    assert EdgeTests.parse("```elixir\ndefmodule A do\nend\n```") == {:error, :no_tests}
  end

  test "failed edge tests come from ExUnit failure headers; an unfinished run fails them all" do
    names = ["empty input", "ordering", "twice"]

    output = """
      1) test ordering (KogenEdge.ListTest)
         test/kogen_edge/edge_probe_test.exs:9

    3 tests, 1 failure
    """

    assert EdgeTests.failed(output, names, {3, 2}) == ["ordering"]
    assert EdgeTests.failed("== Compilation error", names, nil) == names
    assert EdgeTests.failed("3 tests, 0 failures, 3 invalid", names, {3, 3}) == names
  end
end
