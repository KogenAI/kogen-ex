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
    assert result.build.status == :failed
    assert result.build.failure.class == :candidate
    assert result.claim_released
    assert {:ok, report} = Build.report(result)

    assert :json.decode(report)["failures"] |> hd() |> Map.fetch!("reason") ==
             "approved_acceptance_changed"

    assert inspect(result.build) =~ "build-engine_test.exs"
  end

  @tag intent: "approval-base-drift/A3"
  test "an unmoved base builds and lands", %{still: result} do
    assert result.build.status == :landed
  end

  test "base changes to protected support files are used and reported", %{tmp_dir: root} do
    seed =
      Build.prepare_seed!(root,
        project_config: """
        name: tiny_app
        checks:
          - name: helper-current
            argv: [sh, -c, 'test "$(cat test/support/helper.txt)" = current']
            timeout_ms: 60000
        fix: []
        protected_paths: [test/support/**]
        domains:
          kernel: [lib]
        """,
        extra_files: %{"test/support/helper.txt" => "approved\n"}
      )

    result =
      run(root, "support-drift", %Options{
        seed_project: seed,
        move_base_on: {:before_build_file, "test/support/helper.txt", "current\n"}
      })

    assert result.build.status == :landed
    assert {:ok, report} = Build.report(result)

    assert Enum.any?(
             :json.decode(report)["findings"],
             &(&1["type"] == "base_drift" and &1["path"] == "test/support/helper.txt")
           )
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
      ScriptedProvider.finish(),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]
  end
end
