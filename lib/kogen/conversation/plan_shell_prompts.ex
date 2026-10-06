defmodule Kogen.Conversation.PlanShellPrompts do
  @moduledoc false

  alias Kogen.Conversation.PlanPolicy

  @ctx_pack_chars 160_000
  @source Path.expand("../../../priv/prompts/plan-shell.md", __DIR__)
  @external_resource @source
  @plan_system File.read!(@source)
  @difficulty_line "\nBefore the sections, write exactly one line Difficulty: easy, Difficulty: normal or Difficulty: hard. Rate hard for interacting behaviors, subtle edge cases, uncertain APIs, or changes across many files.\n"
  @build_plan_intro "## Implementation plan\n\nThis advisory plan uses only the approved Intent and git ls-files. The planner did not read file contents, confirm installed APIs or versions, edit files, or run checks. Inspect the repository and choose the next useful step; confirm assumptions before relying on them. The approved Intent controls scope. Run useful targeted verification; Kogen owns formatting and the full completion gate.\n\n<plan>\n"

  def planner_system(difficulty \\ false, max_words \\ 500) do
    @plan_system
    |> String.replace("{{word_budget}}", to_string(max_words))
    |> String.replace("{{body_word_budget}}", to_string(max_words - wrapper_words()))
    |> Kernel.<>(if(difficulty, do: @difficulty_line, else: ""))
  end

  def planner_input(task, files) when is_binary(task) and is_binary(files) do
    "TASK (verbatim):\n```\n" <>
      task <>
      "\n```\n\nREPOSITORY FILE LIST (git ls-files):\n```\n" <>
      truncate_file_list(files) <> "```\n"
  end

  def truncate_file_list(files) when is_binary(files) do
    characters = String.to_charlist(files)

    if length(characters) > @ctx_pack_chars do
      (characters |> Enum.take(@ctx_pack_chars) |> List.to_string()) <>
        "\n[file list truncated]\n"
    else
      files
    end
  end

  def builder_addendum(plan) when is_binary(plan), do: @build_plan_intro <> plan <> "\n</plan>\n"

  def measurements(intent_text, max_words) do
    %{
      planner_policy: "concise-ls-files-v1",
      planner_context: "intent_and_file_names",
      intent_bytes: byte_size(intent_text),
      plan_max_words: max_words,
      plan_wrapper_words: wrapper_words()
    }
  end

  defp wrapper_words, do: PlanPolicy.word_count(builder_addendum(""))
end
