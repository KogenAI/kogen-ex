defmodule Kogen.Conversation.PlanShellPromptsTest do
  use Kogen.Testkit.Case

  alias Kogen.Conversation.PlanShellPrompts

  test "planner input caps git ls-files at 160,000 characters and marks truncation" do
    task = "approved Intent"
    files = String.duplicate("x", 160_001)

    assert PlanShellPrompts.planner_input(task, files) ==
             "TASK (verbatim):\n```\napproved Intent\n```\n\n" <>
               "REPOSITORY FILE LIST (git ls-files):\n```\n" <>
               String.duplicate("x", 160_000) <>
               "\n[file list truncated]\n```\n"
  end

  test "builder hand-off accurately describes the planner and preserves the advice" do
    plan = "## Implementation steps\n\n1. Inspect the A1 path."
    text = PlanShellPrompts.builder_addendum(plan)
    assert text =~ "only the approved Intent and git ls-files"
    assert text =~ "planner did not read file contents"
    assert text =~ "approved Intent controls scope"
    assert text =~ "<plan>\n#{plan}\n</plan>\n"
    refute text =~ "scratch copy"
    refute text =~ "Follow the plan"
  end
end
