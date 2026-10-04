defmodule KogenChecks.Check.DomainSizeTest do
  use Credo.Test.Case

  alias KogenChecks.Check.DomainSize

  test "counts the facade and module files in each domain" do
    files = [
      to_source_file("defmodule Kogen.Build do\nend\n", "lib/kogen/build.ex"),
      to_source_file("defmodule Kogen.Build.Loop do\nend\n", "lib/kogen/build/loop.ex")
    ]

    files
    |> run_check(DomainSize, max_lines: 3)
    |> assert_issue(fn issue -> assert issue.message =~ "Domain `build` has 6 lib lines" end)
  end

  test "allows a facade at the configured line limit" do
    "defmodule Kogen.Contracts do\nend\n"
    |> to_source_file("lib/kogen/contracts.ex")
    |> run_check(DomainSize, max_lines: 3)
    |> refute_issues()
  end

  test "counts a separate Tooling domain independently from Harness" do
    files = [
      to_source_file("defmodule Kogen.Harness do\nend\n", "lib/kogen/harness.ex"),
      to_source_file("defmodule Kogen.Tooling do\nend\n", "lib/kogen/tooling.ex"),
      to_source_file("defmodule Kogen.Tooling.Tools do\nend\n", "lib/kogen/tooling/tools.ex")
    ]

    files
    |> run_check(DomainSize, max_lines: 3)
    |> assert_issue(fn issue -> assert issue.message =~ "Domain `tooling` has 6 lib lines" end)
  end
end
