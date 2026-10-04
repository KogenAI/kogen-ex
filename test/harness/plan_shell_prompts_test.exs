defmodule Kogen.Harness.PlanShellPromptsTest do
  use Kogen.Testkit.Case

  alias Kogen.Harness.PlanShellPrompts

  test "planner input caps git ls-files at 160,000 characters and marks truncation" do
    task = "approved Intent"
    files = String.duplicate("x", 160_001)

    assert PlanShellPrompts.planner_input(task, files) ==
             "TASK (verbatim):\n```\napproved Intent\n```\n\n" <>
               "REPOSITORY FILE LIST (git ls-files):\n```\n" <>
               String.duplicate("x", 160_000) <>
               "\n[file list truncated]\n```\n"
  end

  test "builder hand-off preserves the benchmark intro and plan framing exactly" do
    plan = "## Acceptance criteria\n\nA1 passes."

    assert PlanShellPrompts.builder_addendum(plan) ==
             "## Implementation plan\n\n" <>
               "A senior engineer prepared the plan below by investigating a scratch copy of this repository (reading code, running tests and scripts there). " <>
               "The copy was discarded: none of its changes are in your tree. Follow the plan, but confirm its API claims against the installed code before relying on them, and adapt where the repository disagrees. " <>
               "Run the verification steps it lists, including the targeted check of the changed code path, before you finish.\n\n" <>
               "<plan>\n" <> plan <> "\n</plan>\n"
  end
end
