defmodule Kogen.Intent.LintSizeTest do
  use Kogen.Testkit.Case

  alias Kogen.Testkit.IntentFixture

  for size <- ["small", "medium", "large"] do
    test "accepts a valid #{size} Intent" do
      assert Kogen.Intent.lint(IntentFixture.parsed(%{size: unquote(size)})) == []
    end
  end

  for {size, words} <- [{"small", 91}, {"medium", 201}] do
    test "enforces the #{size} Brief word cap" do
      brief = Enum.map_join(1..unquote(words), " ", fn _ -> "clear." end)
      assert :brief_too_long in rules(size: unquote(size), brief: brief)
    end
  end

  for {size, paragraphs} <- [{"small", 2}, {"medium", 3}] do
    test "enforces the #{size} Brief paragraph cap" do
      brief = Enum.map_join(1..unquote(paragraphs), "\n\n", &"Paragraph #{&1} ends.")
      assert :brief_paragraphs in rules(size: unquote(size), brief: brief)
    end
  end

  for {size, count} <- [{"small", 4}, {"medium", 7}] do
    test "enforces the #{size} Acceptance count" do
      items = Enum.map(1..unquote(count), &{"A#{&1}", "Item #{&1} returns a value."})
      verify = Enum.map(items, fn {id, _text} -> {id, "test"} end)
      assert :acceptance_count in rules(size: unquote(size), items: items, verify: verify)
    end
  end

  for {size, words} <- [{"small", 251}, {"medium", 401}] do
    test "enforces the #{size} Notes word cap" do
      notes = Enum.map_join(1..unquote(words), " ", fn _ -> "note" end)
      assert :notes_too_long in rules(size: unquote(size), notes: notes)
    end
  end

  test "Brief rejects a list, heading, and fenced code" do
    assert :list_in_brief in rules(brief: "The change works.\n- First result.")
    assert :heading_in_brief in rules(brief: "The change works.\n## Why it works")
    assert :code_block_in_brief in rules(brief: "The change works.\n```elixir\n:ok\n```")
  end

  test "an Acceptance item may use the 25-word maximum" do
    text = Enum.map_join(1..25, " ", fn _ -> "clear" end) <> "."
    refute :item_too_long in rules(items: [{"A1", text}])
  end

  test "an Acceptance item over 25 words is rejected" do
    text = Enum.map_join(1..26, " ", fn _ -> "clear" end) <> "."
    assert :item_too_long in rules(items: [{"A1", text}])
  end

  test "a 30-word sentence passes and a 31-word Brief sentence fails" do
    thirty = Enum.map_join(1..29, " ", fn _ -> "clear" end) <> " result."
    thirty_one = Enum.map_join(1..30, " ", fn _ -> "clear" end) <> " result."
    refute :sentence_too_long in rules(brief: thirty)
    assert :sentence_too_long in rules(brief: thirty_one)
  end

  test "a long Acceptance sentence is reported" do
    text = Enum.map_join(1..30, " ", fn _ -> "clear" end) <> " result."
    assert :sentence_too_long in rules(items: [{"A1", text}])
  end

  test "an empty Brief is reported" do
    assert :missing_brief in rules(brief: "")
  end

  defp rules(attributes) do
    attributes |> IntentFixture.parsed() |> Kogen.Intent.lint() |> Enum.map(& &1.rule)
  end
end
