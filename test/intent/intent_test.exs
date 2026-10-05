defmodule Kogen.Intent.IntentTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.AcceptanceItem
  alias Kogen.Contracts.Intent

  @source """
  ---
  title: Strip accents
  domains: [intent]
  size: small
  ---
  Slugs keep their readable form. Out of scope: other scripts.

  ## Acceptance
  - A1: "Crème" becomes "creme".

  ## Verify
  - A1: test

  ## Notes
  Read `Kogen.Intent.parse/2` before editing the caller.
  """

  test "parses a binary into the shared Intent and AcceptanceItem structs" do
    assert {:ok, %Intent{} = intent} =
             Kogen.Intent.parse_binary(@source, "strip-accents/intent.md")

    assert intent.slug == "strip-accents"
    assert intent.title == "Strip accents"
    assert intent.size == :small
    assert intent.brief == "Slugs keep their readable form. Out of scope: other scripts."
    assert intent.request == nil
    assert intent.domains == ["intent"]
    assert intent.notes == "Read `Kogen.Intent.parse/2` before editing the caller."

    assert intent.acceptance == [
             %AcceptanceItem{
               id: "A1",
               text: ~s("Crème" becomes "creme".),
               verify: :test,
               domain: nil
             }
           ]

    assert intent.sha256 == Kogen.Intent.hash(@source)
    assert intent.path == "strip-accents/intent.md"
  end

  test "reads the exact file bytes and retains the supplied path", %{tmp_dir: root} do
    path = Path.join([root, "slug-name", "intent.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @source)

    assert {:ok, intent} = Kogen.Intent.parse(path)
    assert intent.path == path
    assert intent.slug == "slug-name"
    assert intent.sha256 == Kogen.Intent.hash(File.read!(path))
  end

  test "hashes exact bytes without whitespace normalization" do
    assert Kogen.Intent.hash("intent\n") ==
             :sha256 |> :crypto.hash("intent\n") |> Base.encode16(case: :lower)

    refute Kogen.Intent.hash("intent\n") == Kogen.Intent.hash("intent")
  end

  test "preserves the Request section verbatim, hashes it, and excludes it from lint" do
    request =
      "ensure robust behaviour without paraphrase\r\n## Notes\r\n```elixir\r\n" <>
        String.duplicate("robust ", 700) <> "TODO??\r\n"

    source = String.trim_trailing(@source) <> "\n\n## Request\n" <> request

    assert {:ok, intent} = Kogen.Intent.parse_binary(source, "strip-accents/intent.md")
    assert intent.request == request
    assert intent.sha256 == Kogen.Intent.hash(source)
    refute intent.sha256 == Kogen.Intent.hash(String.trim_trailing(@source))

    refute Enum.any?(Kogen.Intent.lint(intent), fn issue ->
             issue.rule in [:banned_phrase, :notes_too_long, :open_question]
           end)
  end

  test "reports frontmatter parser errors at source line numbers" do
    source = String.replace(@source, "domains: [intent]", "domains:\t[intent]")

    assert {:error, [%{line: 3, message: message}]} =
             Kogen.Intent.parse_binary(source, "slug/intent.md")

    assert message =~ "tab"

    duplicate = String.replace(@source, "size: small", "size: small\nsize: large")

    assert {:error, [%{line: 5, message: message}]} =
             Kogen.Intent.parse_binary(duplicate, "slug/intent.md")

    assert message =~ "duplicate"
  end

  test "reports missing delimiters and malformed section lines" do
    assert {:error, [%{line: 1, message: opening}]} =
             Kogen.Intent.parse_binary("not an Intent", "slug/intent.md")

    assert opening =~ "start with"

    malformed =
      String.replace(@source, ~s(- A1: "Crème" becomes "creme".), "A1: missing list marker")

    assert {:error, [%{line: 9, message: acceptance}]} =
             Kogen.Intent.parse_binary(malformed, "slug/intent.md")

    assert acceptance =~ "Acceptance entries"
  end

  test "keeps missing and unsupported Verify kinds available to lint" do
    missing = String.replace(@source, "- A1: test", "")
    assert {:ok, intent} = Kogen.Intent.parse_binary(missing, "slug/intent.md")
    assert Enum.any?(Kogen.Intent.lint(intent), &(&1.rule == :missing_verify))

    example = String.replace(@source, "- A1: test", "- A1: example `mix run` exits 0")
    assert {:ok, intent} = Kogen.Intent.parse_binary(example, "slug/intent.md")
    assert Enum.any?(Kogen.Intent.lint(intent), &(&1.message == "example is not supported in P0"))
  end

  test "changes_gate defaults to false and accepts only true or false" do
    assert {:ok, %Intent{changes_gate: false}} = Kogen.Intent.parse_binary(@source, "x/intent.md")

    declared = String.replace(@source, "size: small\n", "size: small\nchanges_gate: true\n")
    assert {:ok, %Intent{changes_gate: true}} = Kogen.Intent.parse_binary(declared, "x/intent.md")

    invalid = String.replace(@source, "size: small\n", "size: small\nchanges_gate: maybe\n")

    assert {:error, [%{line: 5, message: "frontmatter `changes_gate` must be true or false"}]} =
             Kogen.Intent.parse_binary(invalid, "x/intent.md")
  end
end
