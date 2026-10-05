defmodule Kogen.Checks.FeedbackCredoTest do
  use ExUnit.Case, async: true

  alias Kogen.Checks.Feedback

  @workdir "$WORKDIR"

  test "Credo design and readability issues are findings, not an unavailable check" do
    output = """
    mise exec -- mix credo --strict
      Software Design
    ┃
    ┃ [D] ↗ Domain `queue` references Kogen.Kernel.CLI outside its declared
    ┃       dependency graph.
    ┃       test/queue/status_usage_test.exs:4:9 #(Kogen.Queue.StatusUsageTest)

      Code Readability
    ┃
    ┃ [R] → Modules should have a @moduledoc tag.
    ┃       lib/kogen/queue/report.ex:1:11 #(Kogen.Queue.Report)

    make[1]: *** [credo] Error 2
    make: *** [check-full] Error 2
    """

    result =
      Feedback.analyze(%{
        name: "full",
        argv: ["make", "check-full"],
        exit_status: 2,
        timed_out: false,
        output: output,
        log_path: nil,
        workdir: @workdir
      })

    assert result.exit_level == 1

    assert result.findings |> Enum.map(&{&1.tool, &1.path}) |> Enum.sort() == [
             {"credo", "lib/kogen/queue/report.ex"},
             {"credo", "test/queue/status_usage_test.exs"}
           ]

    assert Feedback.render_model_feedback([result]) =~ "outside its declared dependency graph"
  end
end
