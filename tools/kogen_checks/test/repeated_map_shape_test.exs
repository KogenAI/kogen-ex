defmodule KogenChecks.Check.RepeatedMapShapeTest do
  use Credo.Test.Case

  alias KogenChecks.Check.RepeatedMapShape

  test "the same four keys across files expose public parameter and return contracts" do
    sources = [
      to_source_file("defmodule A do\ndef build, do: %{a: 1, b: 2, c: 3, d: 4}\nend", "lib/a.ex"),
      to_source_file(
        "defmodule B do\ndef read(%{d: d, c: c, b: b, a: a}), do: {a,b,c,d}\nend",
        "lib/b.ex"
      ),
      to_source_file("defmodule C do\ndefp data, do: %{a: 1, b: 2, c: 3, d: 4}\nend", "lib/c.ex")
    ]

    issues = run_check(sources, RepeatedMapShape)
    assert Enum.sort(Enum.map(issues, & &1.filename)) == ["lib/a.ex", "lib/b.ex"]

    for issue <- issues do
      assert issue.line_no == 2
      assert issue.message =~ "struct"
      assert issue.exit_status == 0
    end
  end

  test "wrapped and conditional return values are public contracts" do
    """
    defmodule A do
      def run(x) do
        if x do
          {:ok, %{a: 1, b: 2, c: 3, d: 4}}
        else
          {:ok, %{d: 4, a: 1, b: 2, c: 3}}
        end
      end
      defp third, do: %{a: 1, b: 2, c: 3, d: 4}
    end
    """
    |> to_source_file("lib/a.ex")
    |> run_check(RepeatedMapShape)
    |> assert_issues(fn issues -> assert length(issues) == 2 end)
  end

  test "two occurrences, small maps, string keys, updates, private APIs and structs are ignored" do
    for map <- [
          "%{a: 1, b: 2, c: 3}",
          "%{\"a\" => 1, b: 2, c: 3, d: 4}",
          "%Record{a: 1, b: 2, c: 3, d: 4}",
          "%{m | a: 1, b: 2, c: 3, d: 4}"
        ] do
      source =
        "defmodule A do\ndef a(m), do: #{map}\ndef b(m), do: #{map}\ndef c(m), do: #{map}\nend"

      assert [] == source |> to_source_file("lib/a.ex") |> run_check(RepeatedMapShape)
    end

    for visibility <- ["def", "defp"] do
      count = if visibility == "def", do: 2, else: 3

      functions =
        Enum.map_join(1..count, "\n", &"#{visibility} f#{&1}, do: %{a: 1, b: 2, c: 3, d: 4}")

      assert [] ==
               "defmodule A do\n#{functions}\nend"
               |> to_source_file("lib/a.ex")
               |> run_check(RepeatedMapShape)
    end
  end
end
