defmodule Kogen.Acceptance.ReviewFullDiffTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.ScriptedProvider

  @moduletag :acceptance
  @padding String.duplicate(
             "  # padding line to make the change large enough to exceed the tail\n",
             400
           )

  setup_all do
    root = Kogen.Testkit.Temp.create!()
    on_exit(fn -> File.rm_rf!(root) end)
    seed = Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)
    parent = Path.join(root, "review")
    File.mkdir_p!(parent)

    result = Build.run!(parent, script(), %Options{seed_project: seed})
    {:ok, review: review_request(result.build.run_dir)}
  end

  @tag intent: "review-full-diff/A1"
  test "the reviewer sees added files", %{review: review} do
    assert review =~ "ADDED_FILE_MARKER"
  end

  @tag intent: "review-full-diff/A2"
  test "the reviewer sees the start of a large change", %{review: review} do
    assert review =~ "HEAD_OF_LARGE_CHANGE_MARKER"
  end

  @tag intent: "review-full-diff/A3"
  test "the reviewer sees edits to existing files", %{review: review} do
    assert review =~ "def value, do: :ready"
  end

  defp script do
    source =
      "defmodule TinyApp do\n  # HEAD_OF_LARGE_CHANGE_MARKER\n" <>
        @padding <> "  def value, do: :ready\nend\n"

    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0 and add a helper module."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source),
      ScriptedProvider.write(
        :develop,
        "lib/tiny_app/added.ex",
        "defmodule TinyApp.Added do\n  # ADDED_FILE_MARKER\n  def ok, do: :ok\nend\n"
      ),
      ScriptedProvider.finish(),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]
  end

  defp review_request(run_dir) do
    run_dir
    |> Path.join("transcript.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, ~s({"event":"request")))
    |> List.last()
  end
end
