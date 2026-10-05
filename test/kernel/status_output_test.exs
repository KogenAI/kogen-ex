defmodule Kogen.Kernel.StatusOutputTest do
  use ExUnit.Case, async: true

  alias Kogen.Kernel.CLI.StatusOutput
  alias Kogen.Queue.BuildSummary
  alias Kogen.Queue.IntentStatus

  @now 1_800_000_000

  test "the project view is the queue line, then Intents grouped by state" do
    statuses = [
      status("review-full-diff", :building,
        run_id: "f739c9106ed7",
        detail: "develop",
        started_at: @now - 750
      ),
      status("cli-defaults", :approved, approved_at: 20),
      status("approval-checks", :approved, approved_at: 10),
      status("flake-x", :failed, run_id: "7250f70e45447", detail: "repair_cap"),
      status("flake-policy", :draft),
      landed("first", 6),
      landed("second", 5),
      landed("third", 4),
      landed("fourth", 3),
      landed("fifth", 2),
      landed("sixth", 1),
      landed("newest", 0)
    ]

    assert StatusOutput.text(%{statuses: statuses, queue: {:running, 4242}}, @now) == """
           Queue: running (pid 4242)
           Building:
             review-full-diff  develop, 12m (Build f739c910)
           Queued:
             approval-checks
             cli-defaults
           Failed:
             flake-x  repair_cap (Build 7250f70e)
           Drafts:
             flake-policy
           Landed (7):
             newest  0000000a
             sixth   0000000a
             fifth   0000000a
             fourth  0000000a
             third   0000000a
             and 2 earlier
           """
  end

  test "a stopped queue with waiting Intents says how to start it" do
    statuses = [status("a", :approved, approved_at: 1)]

    assert StatusOutput.text(%{statuses: statuses, queue: :stopped}, @now) ==
             "Queue: stopped, 1 waiting; start it with kogen queue start\nQueued:\n  a\n"

    assert StatusOutput.text(%{statuses: [], queue: :stopped}, @now) ==
             "Queue: stopped\nNo Intents.\n"
  end

  test "one Intent shows its state and latest Build" do
    assert StatusOutput.intent_text(status("a", :approved, approved_at: 1), 1, 3, @now) ==
             "a: queued, 2 of 3\n"

    assert StatusOutput.intent_text(landed("a", 0), nil, 0, @now) == "a: landed 0000000a\n"

    assert StatusOutput.intent_text(
             status("a", :building, run_id: "abc", detail: "plan", started_at: @now - 4000),
             nil,
             0,
             @now
           ) == "a: building, plan, 1h06m (Build abc)\n"

    build = %BuildSummary{
      build_id: "7250f70e45447daa",
      run_status: :failed,
      journal: "/runs/7250f70e45447daa",
      reason: "repair_cap",
      stages: [{"context", 70_000}, {"develop", 520_500}],
      candidate_diff: "/runs/7250f70e45447daa/candidate.diff"
    }

    assert StatusOutput.build_text(build) == """
           Build 7250f70e: failed, repair_cap
             model time: context 1m, develop 8m
             candidate diff: /runs/7250f70e45447daa/candidate.diff
             journal: /runs/7250f70e45447daa
           """
  end

  defp status(slug, state, fields \\ []) do
    struct!(%IntentStatus{slug: slug, status: state, run_id: nil, landed_sha: nil}, fields)
  end

  defp landed(slug, index),
    do: status(slug, :landed, landed_sha: "0000000a1111", landed_index: index)
end
