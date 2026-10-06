defmodule Kogen.Kernel.ContinuationStatusTest do
  use ExUnit.Case, async: true

  alias Kogen.Kernel.CLI.StatusOutput
  alias Kogen.Queue.BuildSummary

  test "status exposes continued work within the same Build" do
    text =
      StatusOutput.build_text(%BuildSummary{
        build_id: "abc12345",
        run_status: :landed,
        journal: "/run",
        continuations: 2
      })

    assert text =~ "context continuations: 2"
    assert text =~ "same approved Build"
    assert text =~ "journal: /run"
  end
end
