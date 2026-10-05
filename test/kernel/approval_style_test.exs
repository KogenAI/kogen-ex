defmodule Kogen.Kernel.ApprovalStyleTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Contracts.ShapeWarningCodec
  alias Kogen.Kernel.Approval
  alias Kogen.Kernel.CLI.ErrorOutput
  alias Kogen.Testkit.Git

  test "style findings are review card warnings and the reviewed Intent can be approved", %{
    tmp_dir: tmp_dir
  } do
    repo = project!(tmp_dir)
    bytes = intent("The output should be robust.")
    path = Path.join(repo, ".kogen/intents/style-card/intent.md")
    File.write!(path, bytes)
    warnings_path = Path.join(Path.dirname(path), "shape-warnings.json")
    {:ok, intent} = Kogen.Intent.parse_binary(bytes, ".kogen/intents/style-card/intent.md")

    File.write!(
      warnings_path,
      ShapeWarningCodec.encode(Kogen.Intent.hash(bytes), Kogen.Intent.style_warnings(intent))
    )

    Git.git!(repo, ["add", "--all"])
    Git.git!(repo, ["commit", "--quiet", "-m", "Style advisory fixture"])

    assert {:ok, preview} = Approval.prepare("style-card", repo, repo, "main", "Test", Git.env())
    text = Approval.warnings_text(preview.warnings)
    assert text =~ "  - lint_hedge: A1 — A1 contains a hedge"
    assert text =~ "  - lint_banned_phrase: A1 — A1 contains banned phrase"
    assert text =~ "  - lint_title_too_long: - — title must be at most 72 characters"
    assert length(preview.warnings) == 3
    assert {:ok, %{exit_status: 5, output_tail: card}} = review(repo, tmp_dir)
    assert card =~ text
    assert card =~ "Approve with:"
    assert {:ok, _commit} = Approval.commit(preview)
    assert {:ok, saved} = Kogen.State.approval(repo, "style-card", Git.env())
    assert saved.intent_bytes == bytes
  end

  test "a missing Verify still blocks approval and has no empty line number", %{tmp_dir: tmp_dir} do
    repo = project!(tmp_dir)
    bytes = "The output is exact." |> intent() |> String.replace("- A1: test domain=kernel\n", "")
    File.write!(Path.join(repo, ".kogen/intents/style-card/intent.md"), bytes)

    assert {:error, {:lint, issues}} =
             Approval.prepare("style-card", repo, repo, "main", "Test", Git.env())

    assert {1, text} = ErrorOutput.format({:lint, issues})
    assert text =~ "  missing_verify: every Acceptance item needs a Verify kind"
    refute text =~ "at line :"
  end

  defp review(repo, tmp_dir) do
    {:ok, runtime} = Kogen.Kernel.runtime()
    home = Path.join(tmp_dir, "cli-home")
    File.mkdir_p!(home)

    env =
      Map.merge(runtime.base_env, %{
        "HOME" => home,
        "TMPDIR" => tmp_dir,
        "ERL_FLAGS" => "+S 1:1 +A 1",
        "LC_ALL" => "en_US.UTF-8",
        "LANG" => "en_US.UTF-8"
      })

    ebin = Kogen.Kernel.CLI |> :code.which() |> List.to_string() |> Path.dirname()
    bins = ebin |> Path.dirname() |> Path.dirname() |> Path.join("*/ebin") |> Path.wildcard()

    script =
      "{status, output} = Kogen.Kernel.CLI.execute(System.argv()); IO.write(output); System.halt(status)"

    Kogen.Proc.run(review_argv(bins, script, repo), cd: repo, env: env, timeout_ms: 30_000)
  end

  defp review_argv(bins, script, repo) do
    ["elixir"] ++
      Enum.flat_map(bins, &["-pa", &1]) ++
      [
        "-e",
        script,
        "--",
        "intent",
        "approve",
        "style-card",
        "--project",
        repo,
        "--origin",
        repo,
        "--base",
        "main",
        "--by",
        "Test"
      ]
  end

  defp project!(tmp_dir) do
    repo = Git.create!(tmp_dir)
    Git.git!(repo, ["branch", "-M", "main"])
    File.mkdir_p!(Path.join(repo, ".kogen/intents/style-card"))
    File.mkdir_p!(Path.join(repo, ".kogen/acceptance"))
    File.write!(Path.join(repo, ".kogen/acceptance/style-card_test.exs"), "ExUnit.start()\n")

    File.write!(
      Path.join(repo, ".kogen/project.yaml"),
      "name: style\nchecks: []\nfix: []\ndomains:\n  kernel: [lib]\n"
    )

    repo
  end

  defp intent(item) do
    "---\ntitle: #{String.duplicate("x", 73)}\ndomains: [kernel]\nsize: small\n---\n" <>
      "Return the requested output.\n\n## Acceptance\n- A1: #{item}\n\n## Verify\n- A1: test domain=kernel\n"
  end
end
