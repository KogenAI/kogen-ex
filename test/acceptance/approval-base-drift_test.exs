defmodule Kogen.Acceptance.ApprovalBaseDriftTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.ScriptedProvider

  @moduletag :acceptance

  setup_all do
    root = Kogen.Testkit.Temp.create!()
    on_exit(fn -> File.rm_rf!(root) end)
    seed = Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)

    {:ok,
     moved: run(root, "moved", %Options{seed_project: seed, move_base_on: :before_build}),
     protected:
       run(root, "protected", %Options{seed_project: seed, move_base_on: :before_build_protected}),
     still: run(root, "still", %Options{seed_project: seed})}
  end

  @tag intent: "approval-base-drift/A1"
  test "a moved base still builds and lands", %{moved: result} do
    assert result.build.status == :landed
  end

  @tag intent: "approval-base-drift/A2"
  test "a changed approved test on the base refuses the Build", %{protected: result} do
    assert result.build.status != :landed
    assert inspect(result.build) =~ "build-engine_test.exs"
  end

  @tag intent: "approval-base-drift/A3"
  test "an unmoved base builds and lands", %{still: result} do
    assert result.build.status == :landed
  end

  defp run(root, name, options) do
    parent = Path.join(root, name)
    File.mkdir_p!(parent)
    Build.run!(parent, script(), options)
  end

  defp script do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(
        :develop,
        "lib/tiny_app.ex",
        "defmodule TinyApp do\n  # revision: candidate\n  def value, do: :ready\nend\n"
      ),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]
  end
end
