defmodule Kogen.Contracts.CommandExitTest do
  use ExUnit.Case, async: true

  alias Kogen.Contracts.CommandExit

  test "recognizes both shell command-unavailable statuses" do
    assert CommandExit.tool_missing?(126)
    assert CommandExit.tool_missing?(127)

    refute CommandExit.tool_missing?(0)
    refute CommandExit.tool_missing?(1)
    refute CommandExit.tool_missing?(nil)
  end
end
