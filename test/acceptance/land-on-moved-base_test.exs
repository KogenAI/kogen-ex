defmodule Kogen.Acceptance.LandOnMovedBaseTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :acceptance

  setup_all do
    root = Kogen.Testkit.Temp.create!()
    on_exit(fn -> File.rm_rf!(root) end)
    seed = Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)

    moved = run(root, "moved", %Options{seed_project: seed, move_base_on: :context})
    still = run(root, "still", %Options{seed_project: seed})

    {:ok, moved: moved, still: still}
  end

  @tag intent: "land-on-moved-base/A1"
  test "a moved base is rebased onto and landed", %{moved: result} do
    assert %{status: :landed, landed_sha: sha} = result.build
    origin = result.fixture.origin
    tip_parent = origin |> Git.git!(["rev-parse", "#{sha}^"]) |> String.trim()
    assert tip_parent != result.fixture.approved_base
    assert Git.git!(origin, ["log", "-1", "--format=%s", tip_parent]) =~ "Advance base"
  end

  @tag intent: "land-on-moved-base/A2"
  test "the landed tree is the one the last checks ran on", %{moved: result} do
    assert %{landed_sha: sha} = result.build
    assert is_binary(sha)

    landed_tree =
      result.fixture.origin |> Git.git!(["rev-parse", "#{sha}^{tree}"]) |> String.trim()

    last_check = result.events |> Enum.filter(&(&1.event == "check_result")) |> List.last()
    assert Enum.all?(last_check.receipts, &(&1["tree"] == landed_tree))
  end

  @tag intent: "land-on-moved-base/A3"
  test "an unmoved base lands after a single check run", %{still: result} do
    assert result.build.status == :landed
    assert check_runs(result) == 1
  end

  defp run(root, name, options) do
    parent = Path.join(root, name)
    File.mkdir_p!(parent)
    Build.run!(parent, script(), options)
  end

  defp check_runs(result), do: Enum.count(result.events, &(&1.event == "check_result"))

  defp script do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(
        :develop,
        "lib/tiny_app.ex",
        "defmodule TinyApp do\n  # revision: candidate\n  def value, do: :ready\nend\n"
      ),
      ScriptedProvider.finish(),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]
  end
end
