defmodule Kogen.Runner.ScratchTestsTest do
  use Kogen.Testkit.Case

  alias Kogen.Runner.EdgeTests
  alias Kogen.Runner.ScratchTests

  test "Rails cross-check counts include errors and skips" do
    assert ScratchTests.summary("5 runs, 9 assertions, 1 failures, 1 errors, 1 skips") == {5, 2}
    assert ScratchTests.test_file?("test/models/book_test.rb")
    assert ScratchTests.test_file?("test/book_test.exs")
    refute ScratchTests.test_file?("app/models/book.rb")
  end

  test "Rails edge replies use Ruby tests and report their failing method names" do
    reply = """
    ```ruby
    require "test_helper"
    class KogenEdgeTest < ActiveSupport::TestCase
      test "empty input" do
        assert true
      end
      def test_invalid_input
        assert true
      end
    end
    ```
    """

    assert {:ok, suite} = EdgeTests.parse(reply, :rails)
    assert suite.names == ["test_empty_input", "test_invalid_input"]

    output =
      "Failure:\nKogenEdgeTest#test_invalid_input [test/kogen_edge/edge_probe_test.rb:7]:\nExpected true"

    assert EdgeTests.failed(output, suite.names, {2, 1}) == ["test_invalid_input"]
    assert EdgeTests.run_arguments(:rails) == []
    assert EdgeTests.instructions(:rails) =~ "Minitest"
  end
end
