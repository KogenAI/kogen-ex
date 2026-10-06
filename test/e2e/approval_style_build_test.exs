defmodule Kogen.E2e.ApprovalStyleBuildTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.ScriptedProvider

  @moduletag :e2e
  @moduletag timeout: 300_000

  test "an approved Intent with style warnings builds and lands", %{tmp_dir: tmp_dir} do
    intent = """
    ---
    title: Expose a ready value
    domains: [kernel]
    size: small
    ---
    Ensure the robust TinyApp.value/0 returns the requested value.

    ## Acceptance
    - A1: TinyApp.value/0 should return :ready.

    ## Verify
    - A1: test

    ## Notes
    Keep the implementation inside lib/tiny_app.ex.
    """

    seed = Build.prepare_seed!(Path.join(tmp_dir, "seed"), intent: intent)

    steps = [
      ScriptedProvider.write(
        :develop,
        "lib/tiny_app.ex",
        "defmodule TinyApp do\n  def value, do: :ready\nend\n"
      ),
      ScriptedProvider.finish()
    ]

    result =
      Build.run!(Path.join(tmp_dir, "build"), steps, %Options{
        seed_project: seed,
        recipe: "direct"
      })

    assert result.build.status == :landed
    assert result.run_status == :landed
  end
end
