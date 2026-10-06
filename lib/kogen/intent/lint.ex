defmodule Kogen.Intent.Lint do
  @moduledoc false

  alias Kogen.Contracts.AcceptanceItem
  alias Kogen.Contracts.Intent

  @sizes %{
    small: %{paragraphs: 1, brief_words: 90, items: 3, notes_words: 250},
    medium: %{paragraphs: 2, brief_words: 200, items: 6, notes_words: 400},
    large: %{
      paragraphs: :infinity,
      brief_words: :infinity,
      items: :infinity,
      notes_words: :infinity
    }
  }
  @banned_words ~w(
    ensure ensures ensuring robust robustly seamless seamlessly leverage leverages leveraging
    comprehensive holistic streamline utilize utilizes facilitate facilitates delve crucial
    essential various properly appropriate appropriately gracefully correctly etc moreover
    furthermore additionally overall basically actually simply really very meaningful bounded
    durable authoritative
  )
  @banned_phrases [
    "in order to",
    "it is important",
    "it's important",
    "note that",
    "a variety of",
    "in terms of",
    "as needed",
    "and/or",
    "best practice",
    "best practices",
    "plays a key role",
    "not only",
    "state of the art",
    "end to end",
    "end-to-end",
    "as well as",
    "make sure",
    "take care",
    "where appropriate",
    "if needed",
    "if necessary",
    "at all times",
    "in a way that",
    "with respect to",
    "the ability to"
  ]
  @hedges ~w(should may might could ideally possibly probably generally typically usually)
  @hedge_phrases ["try to", "where possible", "as much as possible"]

  @spec lint(Intent.t()) :: [%{rule: atom(), message: String.t(), line: pos_integer() | nil}]
  def lint(%Intent{} = intent) do
    Enum.flat_map(
      [
        &required_issues/1,
        &brief_issues/1,
        &size_issues/1,
        &identity_issues/1,
        &all_item_issues/1,
        &prose_issues/1,
        &reference_issues/1,
        &open_question_issues/1,
        &long_code_issues/1
      ],
      & &1.(intent)
    )
  end

  # A raw Intent is only its verbatim Request; every other Intent needs a Brief.
  defp required_issues(%Intent{source: :raw, request: request}) do
    if String.trim(request || "") == "",
      do: [issue(:missing_request, "a raw Intent needs a non-empty Request section")],
      else: []
  end

  defp required_issues(%Intent{brief: brief}) do
    if String.trim(brief || "") == "",
      do: [issue(:missing_brief, "write the Brief as prose")],
      else: []
  end

  defp brief_issues(intent) do
    brief = intent.brief || ""
    sized? = Map.has_key?(@sizes, intent.size)

    Enum.reject(
      [
        if(Regex.match?(~r/^\s*(?:[-*+]|\d+[.)])\s/m, brief),
          do: issue(:list_in_brief, "the Brief cannot contain lists")
        ),
        if(Regex.match?(~r/^\s*[#]{1,6}\s/m, brief),
          do: issue(:heading_in_brief, "the Brief cannot contain headings")
        ),
        if(String.contains?(brief, ["```", "~~~"]),
          do: issue(:code_block_in_brief, "the Brief cannot contain code blocks")
        ),
        if(sized? and exceeds?(length(paragraphs(brief)), size_limit(intent.size, :paragraphs)),
          do:
            issue(
              :brief_paragraphs,
              "#{intent.size} Intents allow at most #{size_limit(intent.size, :paragraphs)} Brief paragraphs"
            )
        ),
        if(sized? and exceeds?(word_count(brief), size_limit(intent.size, :brief_words)),
          do:
            issue(
              :brief_too_long,
              "#{intent.size} Intents allow at most #{size_limit(intent.size, :brief_words)} Brief words"
            )
        )
      ],
      &is_nil/1
    )
  end

  defp size_issues(%Intent{size: size}) when not is_map_key(@sizes, size) do
    [issue(:unknown_size, "size must be small, medium, or large")]
  end

  defp size_issues(intent) do
    max_items = size_limit(intent.size, :items)
    notes_words = word_count(intent.notes || "")

    Enum.reject(
      [
        if(intent.acceptance == [] and intent.source != :raw,
          do: issue(:acceptance_count, "Acceptance needs at least one item")
        ),
        if(exceeds?(length(intent.acceptance), max_items),
          do:
            issue(
              :acceptance_count,
              "#{intent.size} Intents allow at most #{max_items} Acceptance items"
            )
        ),
        if(exceeds?(notes_words, size_limit(intent.size, :notes_words)),
          do:
            issue(
              :notes_too_long,
              "#{intent.size} Intents allow at most #{size_limit(intent.size, :notes_words)} Notes words"
            )
        )
      ],
      &is_nil/1
    )
  end

  defp identity_issues(intent) do
    ids = Enum.map(intent.acceptance, & &1.id)
    duplicate_ids = ids |> Enum.frequencies() |> Enum.filter(fn {_id, count} -> count > 1 end)
    expected = if ids == [], do: [], else: for(number <- 1..length(ids), do: "A#{number}")

    Enum.reject(
      [
        if(intent.title == "", do: issue(:missing_title, "title is required")),
        if(String.length(intent.title) > 72,
          do: issue(:title_too_long, "title must be at most 72 characters")
        ),
        if(not Regex.match?(~r/^[a-z0-9][a-z0-9-]{2,47}$/, intent.slug),
          do: issue(:bad_slug, "slug must use 3 to 48 lowercase letters, digits, or dashes")
        ),
        if(intent.domains == [],
          do: issue(:domain_count, "declare at least one domain")
        ),
        if(duplicate_ids != [], do: issue(:duplicate_id, "Acceptance ids must be unique")),
        if(ids != expected,
          do: issue(:sequential_ids, "Acceptance ids must be A1 through An in order")
        )
      ],
      &is_nil/1
    )
  end

  defp all_item_issues(intent) do
    Enum.flat_map(intent.acceptance, &item_issues/1)
  end

  defp item_issues(%AcceptanceItem{} = item) do
    Enum.reject(
      [
        if(word_count(item.text) > 25, do: issue(:item_too_long, "#{item.id} exceeds 25 words")),
        if(item.invalid_verify,
          do: invalid_verify_issue(item),
          else: if(item.verify in [:test, :test_keep], do: nil, else: verify_issue(item.verify))
        ),
        if(
          Enum.any?(@hedges, &contains_phrase?(item.text, &1)) or
            Enum.any?(@hedge_phrases, &contains_phrase?(item.text, &1)),
          do: issue(:hedge, "#{item.id} contains a hedge; state an observable result")
        )
      ],
      &is_nil/1
    )
  end

  defp verify_issue(nil), do: issue(:missing_verify, "every Acceptance item needs a Verify kind")

  defp verify_issue(:example),
    do: issue(:unsupported_verify_kind, "example is not supported in P0")

  defp verify_issue(:check), do: issue(:unsupported_verify_kind, "check is not supported in P0")

  defp verify_issue(kind),
    do: issue(:unsupported_verify_kind, "#{inspect(kind)} is not supported in P0")

  defp invalid_verify_issue(%AcceptanceItem{invalid_verify: word, verify_line: line}) do
    %{issue(:invalid_verify, "unknown Verify word #{inspect(word)}") | line: line}
  end

  defp prose_issues(intent) do
    card = [{"Brief", intent.brief || ""} | Enum.map(intent.acceptance, &{&1.id, &1.text})]

    Enum.flat_map(card, fn {where, text} ->
      banned =
        Enum.map(banned_hits(text), fn phrase ->
          issue(:banned_phrase, "#{where} contains banned phrase #{inspect(phrase)}")
        end)

      long_sentences =
        if Enum.any?(sentences(text), &(word_count(&1) > 30)),
          do: [issue(:sentence_too_long, "#{where} has a sentence over 30 words")],
          else: []

      banned ++ long_sentences
    end)
  end

  defp reference_issues(intent) do
    notes = intent.notes || " "

    ~r/`([^`]+)`/
    |> Regex.scan(notes, capture: :all_but_first)
    |> List.flatten()
    |> Enum.filter(&malformed_reference?/1)
    |> Enum.map(
      &issue(:malformed_ref, "malformed code reference #{inspect(&1)}; use Mod.fun/arity")
    )
  end

  defp open_question_issues(intent) do
    text =
      [intent.brief, intent.notes | Enum.map(intent.acceptance, & &1.text)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    if Regex.match?(~r/\b(?:TBD|TODO|FIXME)\b|\[\s*NEEDS CLARIFICATION|\?\?/i, text),
      do: [issue(:open_question, "remove TBD, TODO, FIXME, or unresolved question markers")],
      else: []
  end

  defp long_code_issues(intent) do
    notes = intent.notes || ""

    ~r/```[^\n]*\n(.*?)```/s
    |> Regex.scan(notes, capture: :all_but_first)
    |> Enum.filter(fn [body] -> length(String.split(body, "\n")) > 16 end)
    |> Enum.map(fn _ ->
      issue(:long_code_block, "Notes code blocks must contain at most 15 lines")
    end)
  end

  defp malformed_reference?(token) do
    candidate =
      String.starts_with?(token, ~w(A B C D E F G H I J K L M N O P Q R S T U V W X Y Z)) and
        String.contains?(token, ".") and reference_candidate?(token)

    candidate and
      not Regex.match?(
        ~r/^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\.[a-z_][A-Za-z0-9_!?]*\/(?:\d+|\*)$/,
        token
      ) and
      not module_reference?(token) and not file_reference?(token)
  end

  defp reference_candidate?(token) do
    String.contains?(token, "/") or
      Regex.match?(
        ~r/^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\.[a-z_][A-Za-z0-9_!?]*$/,
        token
      )
  end

  defp module_reference?(token),
    do: Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*$/, token)

  defp file_reference?(token),
    do: Regex.match?(~r/\.(?:ex|exs|md|yaml|yml|json|toml|txt)$/, token)

  defp banned_hits(text) do
    searchable = text |> strip_inline_code() |> String.downcase()
    phrases = @banned_words ++ @banned_phrases

    Enum.filter(phrases, &contains_phrase?(searchable, &1))
  end

  defp contains_phrase?(text, phrase) do
    escaped = Regex.escape(String.downcase(phrase))

    Regex.match?(
      Regex.compile!("(?:^|[^a-z0-9_])#{escaped}(?:$|[^a-z0-9_])", "i"),
      String.downcase(text)
    )
  end

  defp strip_inline_code(text), do: Regex.replace(~r/`[^`]*`/, text, " ")
  defp paragraphs(text), do: String.split(text, ~r/\n\s*\n/, trim: true)
  defp sentences(text), do: Regex.split(~r/(?<=[.!?])\s+/, text, trim: true)
  defp word_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()

  defp exceeds?(_count, :infinity), do: false
  defp exceeds?(count, limit), do: count > limit

  defp size_limit(size, key) do
    case Map.fetch(@sizes, size) do
      {:ok, limits} -> Map.fetch!(limits, key)
      :error -> 0
    end
  end

  defp issue(rule, message), do: %{rule: rule, message: message, line: nil}
end
