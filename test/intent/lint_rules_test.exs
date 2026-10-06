defmodule Kogen.Intent.LintRulesTest do
  use Kogen.Testkit.Case

  alias Kogen.Testkit.IntentFixture

  test "flags direct hedges in acceptance items" do
    assert :hedge in rules(items: [{"A1", "The output should be exact."}])
  end

  test "flags hedge phrases in acceptance items" do
    assert :hedge in rules(items: [{"A1", "The output is exact where possible."}])
    assert :hedge in rules(items: [{"A1", "Try to return the same value."}])
  end

  @banned_cases [
    {"ensure", "The writer ensures the output has a stable shape."},
    {"robust", "The robust writer returns one value."},
    {"bounded", "The bounded writer returns one value."},
    {"authoritative", "The authoritative writer returns one value."},
    {"in order to", "The writer returns a value in order to help callers."},
    {"as needed", "The writer returns a value as needed."},
    {"and/or", "The writer accepts a name and/or a label."},
    {"end-to-end", "The end-to-end path returns one value."},
    {"not only", "The writer returns not only a name but also a label."},
    {"make sure", "The caller must make sure the value is stable."}
  ]

  for {phrase, brief} <- @banned_cases do
    test "flags the planted #{phrase} phrase" do
      assert :banned_phrase in rules(brief: unquote(brief))
    end
  end

  test "ignores a banned phrase inside inline code" do
    refute :banned_phrase in rules(brief: "The `robust` function returns one value.")
  end

  test "reports duplicate Acceptance ids" do
    items = [{"A1", "First value is exact."}, {"A1", "Second value is exact."}]
    verify = [{"A1", "test"}]
    assert :duplicate_id in rules(items: items, verify: verify)
  end

  test "reports ids that are not sequential" do
    items = [{"A1", "First value is exact."}, {"A3", "Third value is exact."}]
    verify = [{"A1", "test"}, {"A3", "test"}]
    assert :sequential_ids in rules(items: items, verify: verify)
  end

  test "requires a Verify kind and rejects unknown modifiers" do
    assert :missing_verify in rules(verify: [])
    assert :invalid_verify in rules(verify: [{"A1", "test maybe"}])
  end

  test "requires a title and at least one Acceptance item" do
    assert :missing_title in rules(title: "")
    assert :acceptance_count in rules(items: [], verify: [])
  end

  test "rejects example and check Verify kinds in P0" do
    assert unsupported_message("example `mix run` exits 0") == "example is not supported in P0"
    assert unsupported_message("check unit") == "check is not supported in P0"
  end

  test "accepts numeric Mod.fun/arity references and module outlines" do
    assert Kogen.Intent.lint(
             IntentFixture.parsed(
               notes: "Read `Kogen.Intent.parse/2` and the `Kogen.Intent` outline."
             )
           ) == []
  end

  test "rejects malformed function references" do
    assert :malformed_ref in rules(notes: "Read `Kogen.Intent.parse/two` first.")
    assert :malformed_ref in rules(notes: "Read `Kogen.Intent.parse` first.")
  end

  test "does not treat a Markdown filename as a symbol reference" do
    assert Kogen.Intent.lint(IntentFixture.parsed(notes: "Read `README.md` first.")) == []
  end

  test "flags unresolved questions carried into the Intent" do
    assert :open_question in rules(notes: "TODO: settle the command name.")
  end

  test "caps fenced code in Notes at 15 lines" do
    code = Enum.map_join(1..17, "\n", &"line_#{&1}")
    assert :long_code_block in rules(notes: "```text\n#{code}\n```")
  end

  test "enforces title, size, slug, and declared-domain bounds" do
    assert :title_too_long in rules(title: String.duplicate("x", 73))
    assert :unknown_size in rules(size: "huge")
    assert :bad_slug in rules(slug: "Bad_slug")
    assert :domain_count in rules(domains: [])
  end

  @tag intent: "valid-intent/A1"
  test "Acceptance ids compose into the global intent tag" do
    intent = IntentFixture.parsed()
    item = hd(intent.acceptance)
    assert "#{intent.slug}/#{item.id}" == "valid-intent/A1"
  end

  defp rules(attributes) do
    attributes |> IntentFixture.parsed() |> Kogen.Intent.lint() |> Enum.map(& &1.rule)
  end

  defp unsupported_message(kind) do
    [verify: [{"A1", kind}]]
    |> IntentFixture.parsed()
    |> Kogen.Intent.lint()
    |> Enum.find(&(&1.rule == :unsupported_verify_kind))
    |> Map.fetch!(:message)
  end
end
