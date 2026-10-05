defmodule Kogen.Shaper.Validation do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Intent, as: IntentDomain
  alias Kogen.Project.GatePaths

  @approach_action ~r/\b(?:add|advance|calculate|change|compare|compute|count|derive|extend|filter|handle|implement|keep|limit|map|move|normalize|parse|preserve|record|replace|return|route|run|schedule|shift|skip|store|update|use|validate|wrap)\b/i
  @approach_action_at_start ~r/\A(?:add|advance|calculate|change|compare|compute|count|derive|extend|filter|handle|implement|keep|limit|map|move|normalize|parse|preserve|record|replace|return|route|run|schedule|shift|skip|store|update|use|validate|wrap)\b/i
  @notes_section ~r/(^## Notes[ \t]*\R)(.*?)(?=^## Request[ \t]*\R|\z)/ms
  @approach_label ~r/\A(\s*)approach\s*:\s*(.*)\z/is

  @spec normalize_intent(binary()) :: binary()
  def normalize_intent(source) when is_binary(source) do
    case Regex.run(@notes_section, source) do
      [matched, heading, notes] ->
        String.replace_suffix(source, matched, heading <> normalize_approach(notes))

      _no_notes_section ->
        source
    end
  end

  @spec intent(binary(), Path.t()) :: {:ok, Intent.t()} | {:error, Failure.t()}
  def intent(bytes, path), do: intent(bytes, path, nil)

  @spec intent(binary(), Path.t(), Kogen.Contracts.Project.t() | nil) ::
          {:ok, Intent.t()} | {:error, Failure.t()}
  def intent(bytes, path, project) do
    case IntentDomain.parse_binary(bytes, path) do
      {:ok, %Intent{} = intent} ->
        lint(intent, bytes, project)

      {:error, issues} ->
        {:error, failure(:intent_parse_failed, render_parse_issues(issues, bytes))}
    end
  end

  defp lint(%Intent{} = intent, source, project) do
    issues =
      IntentDomain.lint(intent) ++ approach_issues(intent) ++ gate_path_issues(intent, project)

    case issues do
      [] ->
        {:ok, intent}

      issues ->
        {:error, failure(:intent_lint_failed, render_lint_issues(issues, intent, source))}
    end
  end

  defp gate_path_issues(%Intent{changes_gate: true}, _project), do: []
  defp gate_path_issues(_intent, nil), do: []

  defp gate_path_issues(%Intent{notes: notes}, project) do
    case GatePaths.referenced_path(GatePaths.effective(project), notes || "") do
      nil ->
        []

      path ->
        [
          %{
            rule: :undeclared_gate_path,
            message: "Gate-path edit requires `changes_gate: true`; matched path #{path}.",
            line: nil
          }
        ]
    end
  end

  defp approach_issues(%Intent{notes: notes}) do
    text = if is_binary(notes), do: String.trim(notes), else: ""
    approach = Regex.run(~r/\AApproach:\s*(.+)\z/is, text, capture: :all_but_first)

    if valid_approach?(approach) do
      []
    else
      [
        %{
          rule: :missing_approach,
          message:
            "Notes must begin with `Approach:` and describe implementation; acceptance criteria alone are not a plan.",
          line: nil
        }
      ]
    end
  end

  defp valid_approach?([text]) do
    word_count = text |> String.split(~r/\s+/, trim: true) |> length()
    word_count >= 8 and Regex.match?(@approach_action, text)
  end

  defp valid_approach?(_missing), do: false

  defp normalize_approach(notes) do
    case Regex.run(@approach_label, notes) do
      [_, leading, text] ->
        leading <> "Approach: " <> String.trim_leading(text)

      _missing_label ->
        text = String.trim_leading(notes)
        word_count = text |> String.split(~r/\s+/, trim: true) |> length()

        if word_count >= 8 and Regex.match?(@approach_action_at_start, text),
          do: "Approach: " <> text,
          else: notes
    end
  end

  defp render_parse_issues(issues, source) do
    lines = String.split(source, "\n", trim: false)

    Enum.map_join(issues, "", fn issue ->
      line = Map.get(issue, :line)
      location = if line, do: " at line #{line}", else: ""
      source_line = if line, do: Enum.at(lines, line - 1)
      detail = if source_line, do: "\n  Source text: #{inspect(source_line)}", else: ""
      "parse#{location}: #{issue.message}#{detail}\n"
    end)
  end

  defp render_lint_issues(issues, %Intent{} = intent, source) do
    lines = String.split(source, "\n", trim: false)

    Enum.map_join(issues, "", fn issue ->
      line = Map.get(issue, :line)
      location = if line, do: " at line #{line}", else: ""

      source_text =
        case lint_subject(issue, intent) do
          {label, text} when is_binary(text) ->
            value = if text == "", do: "<missing>", else: inspect(text)
            "\n  #{label} text: #{value}"

          _none ->
            issue_source(issue, lines, line)
        end

      "lint#{location} [#{issue.rule}]: #{issue.message}\n" <>
        "  Rule: #{lint_rule(issue.rule)}#{source_text}\n"
    end)
  end

  defp lint_subject(issue, %Intent{} = intent) do
    item = lint_item(issue, intent)

    cond do
      item ->
        {"Acceptance item #{item.id}", item.text}

      issue.rule in [
        :missing_brief,
        :list_in_brief,
        :heading_in_brief,
        :code_block_in_brief,
        :brief_paragraphs,
        :brief_too_long
      ] ->
        {"Brief", intent.brief}

      issue.rule in [
        :notes_too_long,
        :malformed_ref,
        :long_code_block,
        :missing_approach,
        :undeclared_gate_path
      ] ->
        {"Notes", intent.notes || ""}

      issue.rule in [:missing_title, :title_too_long] ->
        {"Frontmatter title", intent.title}

      true ->
        nil
    end
  end

  defp lint_item(issue, %Intent{} = intent) do
    case Regex.run(~r/\b(A\d+)\b/, issue.message, capture: :all_but_first) do
      [id] ->
        Enum.find(intent.acceptance, &(&1.id == id))

      _none ->
        Enum.find(intent.acceptance, &item_for_rule?(&1, issue))
    end
  end

  defp item_for_rule?(item, %{rule: :missing_verify}), do: is_nil(item.verify)
  defp item_for_rule?(item, %{rule: :invalid_verify, line: line}), do: item.verify_line == line

  defp item_for_rule?(item, %{rule: :unsupported_verify_kind}),
    do: item.verify not in [:test, :test_keep]

  defp item_for_rule?(_item, _issue), do: false

  defp issue_source(%{rule: :unknown_size}, lines, _line),
    do: matching_source_line(lines, ~r/^\s*size\s*:/)

  defp issue_source(%{rule: :domain_count}, lines, _line),
    do: matching_source_line(lines, ~r/^\s*domains\s*:/)

  defp issue_source(_issue, _lines, line) when not is_integer(line), do: ""

  defp issue_source(_issue, lines, line) do
    case Enum.at(lines, line - 1) do
      text when is_binary(text) -> "\n  Source text: #{inspect(text)}"
      _missing -> ""
    end
  end

  defp matching_source_line(lines, pattern) do
    case Enum.find(lines, &Regex.match?(pattern, &1)) do
      text when is_binary(text) -> "\n  Source text: #{inspect(text)}"
      _missing -> ""
    end
  end

  defp lint_rule(:item_too_long), do: "Each Acceptance item must contain at most 25 words."

  defp lint_rule(:hedge),
    do: "Acceptance items must state a definite, observable result without hedge words."

  defp lint_rule(:missing_verify), do: "Every Acceptance item needs one Verify line."

  defp lint_rule(:invalid_verify),
    do: "Use `test` or `test keep` with a configured project domain."

  defp lint_rule(:unsupported_verify_kind),
    do: "P0 supports only `test` and `test keep` Verify kinds."

  defp lint_rule(:banned_phrase),
    do: "Use precise direct wording and remove the flagged word or phrase."

  defp lint_rule(:sentence_too_long),
    do: "Brief and Acceptance sentences must be at most 30 words."

  defp lint_rule(:missing_approach),
    do:
      "Notes must begin with `Approach:`, name the code path and implementation mechanism, and state behavior to preserve; do not restate acceptance criteria."

  defp lint_rule(:unknown_size), do: "Use exactly `small`, `medium`, or `large` for size."

  defp lint_rule(:heading_in_brief),
    do: "The Brief is prose and must not include a heading such as `## Brief`."

  defp lint_rule(:list_in_brief), do: "The Brief must be prose without list formatting."

  defp lint_rule(:brief_too_long),
    do: "Keep the Brief within the word limit for its declared size."

  defp lint_rule(:brief_paragraphs),
    do: "Keep the Brief within the paragraph limit for its declared size."

  defp lint_rule(:acceptance_count),
    do: "Keep the number of Acceptance items within the limit for the declared size."

  defp lint_rule(:sequential_ids), do: "Acceptance ids must run in order from A1 through An."
  defp lint_rule(:duplicate_id), do: "Every Acceptance id must be unique."

  defp lint_rule(_rule),
    do: "Follow the Intent format and size rules stated in the shaper instructions."

  defp failure(reason, detail), do: %Failure{class: :candidate, reason: reason, detail: detail}
end
