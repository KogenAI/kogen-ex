defmodule Kogen.Contracts.ShapeWarning do
  @moduledoc "A deterministic warning produced while shaping an Intent."

  @enforce_keys [:code, :item_ids, :message]
  defstruct @enforce_keys

  @codes ~w(shape_reclassified lint_banned_phrase lint_hedge lint_brief_paragraphs
    lint_brief_too_long lint_notes_too_long lint_acceptance_count lint_item_too_long
    lint_sentence_too_long lint_long_code_block lint_title_too_long)a

  def codes, do: @codes

  @type t :: %__MODULE__{
          code: atom(),
          item_ids: [String.t()],
          message: String.t()
        }
end
