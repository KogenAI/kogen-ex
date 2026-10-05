defmodule Kogen.State.JournalRedactionTest do
  use Kogen.Testkit.Case

  alias Kogen.State
  alias Kogen.State.Approval

  test "the run journal never stores a credential from a failure detail", context do
    token = "eyJhbGciOiJSUzI1NiJ9." <> String.duplicate("fAkEpAyLoAd", 4)
    detail = ~s(State: {~c"authorization", ~c"Bearer #{token}"} {"refresh_token":"fake-rt"})
    {:ok, run} = State.start_run(context.tmp_dir, approval())

    assert :ok =
             State.record(run, %{event: :stage_failure, class: :provider, detail: detail})

    assert :ok = State.record(run, %{event: :finished, status: :failed, reason: :transport})

    for file <- ["events.jsonl", "run.json"] do
      text = run.dir |> Path.join(file) |> File.read!()
      refute text =~ token
      refute text =~ "fake-rt"
      text |> String.split("\n", trim: true) |> Enum.each(&:json.decode/1)
    end

    assert run.dir |> Path.join("events.jsonl") |> File.read!() =~ "Bearer [REDACTED]"
  end

  defp approval do
    bytes = "# Demo feature\n"

    %Approval{
      slug: "demo-feature",
      intent_bytes: bytes,
      intent_sha256: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
      target_branch: "main",
      base_sha: "base-sha",
      domains: ["lib/kogen/state"],
      acceptance_files: %{},
      protected_manifest: %{},
      by: "Almir",
      at: ~U[2026-10-02 10:15:30Z]
    }
  end
end
