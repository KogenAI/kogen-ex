defmodule Kogen.State.PhaseTimingTest do
  use Kogen.Testkit.Case

  alias Kogen.State
  alias Kogen.State.Approval
  alias Kogen.State.Event

  setup %{tmp_dir: root} do
    bytes = "# Phase timing\n"

    approval = %Approval{
      slug: "phase-timing",
      intent_bytes: bytes,
      intent_sha256: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
      target_branch: "main",
      base_sha: "base",
      domains: ["state"],
      acceptance_files: %{},
      protected_manifest: %{},
      by: "Test",
      at: ~U[2026-10-06 12:00:00Z]
    }

    {:ok, run} = State.start_run(root, approval)
    {:ok, run: run}
  end

  test "preserves operation results and writes one timing event", %{run: run} do
    assert {:error, :candidate_failed} =
             State.measure_phase(run, "build", "check", fn -> {:error, :candidate_failed} end)

    assert [%Event{event: "phase_timing", phase: "build", name: "check"} = event] = events(run)
    assert is_integer(event.wall_ms) and event.wall_ms >= 0
    assert is_integer(event.started_at)
    assert event.finished_at >= event.started_at
  end

  test "records timing when an operation raises and preserves the exception", %{run: run} do
    assert_raise ArgumentError, "operation failed", fn ->
      State.measure_phase(run, "build", "commit", fn ->
        raise ArgumentError, "operation failed"
      end)
    end

    assert [%Event{event: "phase_timing", phase: "build", name: "commit"}] = events(run)
  end

  defp events(run) do
    run.dir
    |> Path.join("events.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      {:ok, event} = State.decode_event(line)
      event
    end)
  end
end
