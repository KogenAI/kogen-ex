defmodule Kogen.Intent.Advisory do
  @moduledoc false

  alias Kogen.Contracts.ShapeWarning

  @codes %{
    banned_phrase: :lint_banned_phrase,
    hedge: :lint_hedge,
    brief_paragraphs: :lint_brief_paragraphs,
    brief_too_long: :lint_brief_too_long,
    notes_too_long: :lint_notes_too_long,
    acceptance_count: :lint_acceptance_count,
    item_too_long: :lint_item_too_long,
    sentence_too_long: :lint_sentence_too_long,
    long_code_block: :lint_long_code_block,
    title_too_long: :lint_title_too_long
  }

  def style?(%{rule: :acceptance_count, message: message}),
    do: not String.contains?(message, "at least one")

  def style?(%{rule: rule}), do: Map.has_key?(@codes, rule)

  def warning(issue) do
    ids = ~r/\bA\d+\b/ |> Regex.scan(issue.message) |> List.flatten() |> Enum.uniq()
    %ShapeWarning{code: Map.fetch!(@codes, issue.rule), item_ids: ids, message: issue.message}
  end
end
