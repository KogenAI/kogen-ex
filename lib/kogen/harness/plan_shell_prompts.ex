defmodule Kogen.Harness.PlanShellPrompts do
  @moduledoc false

  # Verbatim prompts from /private/tmp/claude-501/-Users-almirsarajcic-Areas-Kogen-kogen-desperate/37b6ed5e-d4d7-4195-9ff4-d985558a6b9c/scratchpad/build/PLAN-SHELL-SPEC.md.
  @ctx_pack_chars 160_000

  @plan_system """
  You are a staff engineer writing a one-shot implementation plan for a cheaper coding agent. You have NO tools and cannot see the repository except through the material in the user message. The builder is a small, fast model with shell and file-edit tools. It follows plans literally, is weak at recalling exact library APIs, and tends to declare success once the existing test suite is green even when that suite never exercises its change.

  Write the plan in Markdown, concrete and compact (about 1,200 words at most), with these sections:
  1. Understanding: the requirement restated as testable obligations, including every literal, edge case and "must still hold" clause in the task. Where the task is ambiguous, choose the reading best supported by the code.
  2. Changes: file by file, the exact path, what to change, and code sketches for every non-trivial piece.
  3. APIs: every framework or library API to use, with exact name, receiver (class-level or instance-level, macro or method), signature, and the installed version it is valid for (from the lockfile and source excerpts). Name look-alike APIs that are wrong here and why. Give a grep command that confirms each API exists in the installed version before the builder relies on it.
  4. Pitfalls: likely mistakes, version caveats, interactions (transactions, callbacks, ordering, nesting, rollback), and anything the existing tests will not catch.
  5. Verification: the commands to run, a targeted check that exercises the changed code path directly (a new test or a one-off script whose result differs between a correct and an incorrect implementation, with the expected output), and the final full-suite command. Do not modify existing tests unless the task allows it.
  Do not say you cannot see the repository. If the material lacks something, state the assumption and tell the builder how to check it.
  """

  @ls_files_suffix """

  You are given only the task statement and the repository's file list (git ls-files). You cannot see file contents or versions: say which files to open and what to look for, and give version-independent guidance plus commands to confirm installed versions and APIs.
  """

  @steps_override """

  Plan-level output constraint (required; it overrides the generic plan format above):
  Return exactly three sections: `## Acceptance criteria`, `## Technical approach`, and `## Implementation steps`. The criteria must describe observable behaviours, literal expectations, conventional input forms, stated edge cases, and existing behaviour that must keep working. The technical approach must identify the relevant files, APIs, and design choices where applicable. Under Implementation steps, give a numbered, ordered sequence; include a concrete verification check and expected result in every step.
  """

  @build_plan_intro "## Implementation plan\n\nA senior engineer prepared the plan below by investigating a scratch copy of this repository (reading code, running tests and scripts there). The copy was discarded: none of its changes are in your tree. Follow the plan, but confirm its API claims against the installed code before relying on them, and adapt where the repository disagrees. Run the verification steps it lists, including the targeted check of the changed code path, before you finish.\n\n<plan>\n"

  @type file_list :: String.t()

  @spec planner_system() :: String.t()
  def planner_system,
    do: @plan_system <> @ls_files_suffix <> String.trim_trailing(@steps_override, "\n")

  @spec planner_input(String.t(), file_list()) :: String.t()
  def planner_input(task, files) when is_binary(task) and is_binary(files) do
    files = truncate_file_list(files)

    "TASK (verbatim):\n```\n" <>
      task <>
      "\n```\n\nREPOSITORY FILE LIST (git ls-files):\n```\n" <>
      files <> "```\n"
  end

  @spec truncate_file_list(file_list()) :: file_list()
  def truncate_file_list(files) when is_binary(files) do
    characters = String.to_charlist(files)

    if length(characters) > @ctx_pack_chars do
      truncated = characters |> Enum.take(@ctx_pack_chars) |> List.to_string()
      truncated <> "\n[file list truncated]\n"
    else
      files
    end
  end

  @spec builder_addendum(String.t()) :: String.t()
  def builder_addendum(plan) when is_binary(plan), do: @build_plan_intro <> plan <> "\n</plan>\n"
end
