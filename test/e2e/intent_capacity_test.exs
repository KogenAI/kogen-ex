defmodule Kogen.E2e.IntentCapacityTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Ladder
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Temp

  @moduletag :e2e
  @moduletag timeout: 300_000

  setup_all do
    root = Temp.create!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, seed: Ladder.seed!(root, intent: intent(), acceptance: acceptance())}
  end

  test "one approval delivers all twelve outcomes together in one commit", context do
    result = Ladder.run!(context.tmp_dir, "complete", script(12), context.seed, "direct-shell")
    assert result.build.status == :landed
    assert {:ok, report} = Build.report(result)
    decoded = :json.decode(report)
    assert length(decoded["acceptance_results"]) == 12
    assert Enum.all?(decoded["acceptance_results"], &(&1["status"] == "passed"))
    assert decoded["progress"] == %{"verified" => ids(12), "remaining" => []}

    assert Git.git!(result.fixture.origin, [
             "rev-list",
             "--count",
             "#{result.fixture.approved_base}..#{result.build.landed_sha}"
           ]) == "1\n"
  end

  test "a failed twelfth outcome keeps the whole change unfinished and reports the remainder",
       context do
    result = Ladder.run!(context.tmp_dir, "partial", script(11), context.seed, "direct-shell")
    assert result.build.status == :failed
    assert result.build.landed_sha == nil
    assert {:ok, report} = Build.report(result)
    decoded = :json.decode(report)
    assert decoded["status"] == "failed"
    assert decoded["progress"] == %{"verified" => ids(11), "remaining" => ["A12"]}

    assert Enum.find(decoded["acceptance_results"], &(&1["tag"] == "build-engine/A12"))["status"] ==
             "failed"
  end

  defp script(count) do
    source =
      "defmodule TinyApp do\n  def value, do: :ready\n  def part(n) when n <= #{count}, do: {:ready, n}\n  def part(_n), do: :unfinished\nend\n"

    [
      Ladder.shell("cat > lib/tiny_app.ex <<'EOF'\n#{source}EOF")
      | List.duplicate(Ladder.done(), 8)
    ]
  end

  defp ids(count), do: Enum.map(1..count, &"A#{&1}")

  defp intent do
    items =
      Enum.map_join(
        1..12,
        "\n",
        &"- A#{&1}: Part #{&1} returns its ready value under the shared contract."
      )

    verifies = Enum.map_join(1..12, "\n", &"- A#{&1}: test")

    "---\ntitle: Deliver the complete feature\ndomains: [kernel]\nsize: large\n---\nDeliver every part with the same ready tuple contract.\n\n## Acceptance\n#{items}\n\n## Verify\n#{verifies}\n\n## Notes\nApproach: Extend TinyApp with all twelve parts and preserve their shared tuple format.\n"
  end

  defp acceptance do
    tests =
      Enum.map_join(1..12, "\n", fn n ->
        "  @tag intent: \"build-engine/A#{n}\"\n  test \"part #{n}\" do\n    assert TinyApp.part(#{n}) == {:ready, #{n}}\n  end\n"
      end)

    "defmodule TinyApp.CapacityTest do\n  use ExUnit.Case, async: true\n#{tests}end\n"
  end
end
