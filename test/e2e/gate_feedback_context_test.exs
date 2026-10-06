defmodule Kogen.E2e.GateFeedbackContextTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.ScriptedProvider

  @moduletag :e2e
  @moduletag timeout: 300_000

  test "a red gate sends project context and changed ranges to the builder, which repairs and lands",
       %{tmp_dir: tmp_dir} do
    seed = Kogen.E2e.Ladder.seed!(Path.join(tmp_dir, "seed"))
    broken = "defmodule TinyApp do\n  def value, do: raise(\"candidate bug\")\nend\n"
    repaired = "defmodule TinyApp do\n  def value, do: :ready\nend\n"

    steps = [
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", broken),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", repaired),
      ScriptedProvider.answer(:develop, "Done.")
    ]

    result = Build.run!(tmp_dir, steps, %Options{seed_project: seed, recipe: "direct"})
    assert result.build.status == :landed

    text =
      Enum.map_join(result.provider_requests, "\n", fn request ->
        Enum.map_join(request.input, "\n", &inspect/1)
      end)

    assert text =~ "TinyApp.AcceptanceTest"
    assert text =~ "returns the ready value"
    assert text =~ "test/acceptance/build-engine_test.exs:"
    assert text =~ "code: assert TinyApp.value() == :ready"
    assert text =~ "candidate bug"
    assert text =~ "project: lib/tiny_app.ex:2"
    assert text =~ "Candidate changes relative to Build base:"
    assert text =~ "lib/tiny_app.ex: base"
  end
end
