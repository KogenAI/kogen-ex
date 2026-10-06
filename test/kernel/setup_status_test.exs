defmodule Kogen.Kernel.SetupStatusTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Kernel.CLI.StatusOutput
  alias Kogen.Queue.BuildSummary
  alias Kogen.State.Json
  alias Kogen.State.Run

  test "status reports preparation time and cache reuse from the journal", %{tmp_dir: root} do
    directory = Path.join([root, "runs", "setup-test"])
    File.mkdir_p!(directory)

    run = %Run{
      id: "setup-test",
      dir: directory,
      slug: "setup",
      intent_sha256: String.duplicate("a", 64),
      target_branch: "main",
      approval_commit: nil,
      status: :failed,
      landing: nil
    }

    {:ok, bytes} = Json.encode_run(run)
    File.write!(Path.join(directory, "run.json"), bytes)

    File.write!(
      Path.join(directory, "events.jsonl"),
      ~s({"event":"setup_prepared","wall_ms":42}\n)
    )

    assert {:ok, summary} = BuildSummary.latest(root, "setup")
    assert StatusOutput.build_text(summary) =~ "setup: prepared in 42 ms"

    File.write!(
      Path.join(directory, "events.jsonl"),
      ~s({"event":"setup_reused","saved_wall_ms":42}\n)
    )

    assert {:ok, summary} = BuildSummary.latest(root, "setup")
    assert StatusOutput.build_text(summary) =~ "setup: reused (saved preparation 42 ms)"
  end
end
