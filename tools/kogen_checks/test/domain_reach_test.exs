defmodule KogenChecks.Check.DomainReachTest do
  use Credo.Test.Case

  alias KogenChecks.Check.DomainReach

  test "flags a call into another domain, allows own + contracts" do
    """
    defmodule Kogen.Build.Cycle do
      alias Kogen.Contracts.Effect
      alias Kogen.Build.State
      def step(s), do: Kogen.Checks.Runner.run(s) && %Effect{} && State.x()
    end
    """
    |> to_source_file("lib/kogen/build/cycle.ex")
    |> run_check(DomainReach)
    |> assert_issue(fn i -> assert i.trigger == "Kogen.Checks.Runner" end)
  end

  test "tests are scoped to their domain too; testkit is shared support" do
    "defmodule Kogen.Build.CycleTest do\n  def t, do: Kogen.Workspace.Git.x()\nend\n"
    |> to_source_file("test/build/cycle_test.exs")
    |> run_check(DomainReach, also_allowed: [Kogen.Testkit])
    |> assert_issue()

    "defmodule Kogen.Kernel.Wiring do\n  def w, do: Kogen.Workspace.Git.x()\nend\n"
    |> to_source_file("lib/kogen/kernel/wiring.ex")
    |> run_check(DomainReach, dependencies: %{Kogen.Kernel => [Kogen.Workspace]})
    |> refute_issues()

    "defmodule Kogen.Kernel.Wiring do\n  def w, do: Kogen.Checks.Runner.x()\nend\n"
    |> to_source_file("lib/kogen/kernel/wiring.ex")
    |> run_check(DomainReach, dependencies: %{Kogen.Kernel => [Kogen.Workspace]})
    |> assert_issue()
  end

  test "allows declared acyclic dependencies" do
    "defmodule Kogen.Workspace.Git do\n  def w, do: Kogen.Proc.Runner.run([])\nend\n"
    |> to_source_file("lib/kogen/workspace/git.ex")
    |> run_check(DomainReach, dependencies: %{Kogen.Workspace => [Kogen.Proc]})
    |> refute_issues()
  end

  test "Builder Tooling depends on process execution without reaching back into Harness" do
    "defmodule Kogen.Tooling.Tools do\n  def run(call), do: Kogen.Proc.Runner.run(call)\nend\n"
    |> to_source_file("lib/kogen/tooling/tools.ex")
    |> run_check(DomainReach, dependencies: %{Kogen.Tooling => [Kogen.Proc]})
    |> refute_issues()

    "defmodule Kogen.Tooling.Tools do\n  def run(opts), do: Kogen.Harness.Opts.new(opts)\nend\n"
    |> to_source_file("lib/kogen/tooling/tools.ex")
    |> run_check(DomainReach, dependencies: %{Kogen.Tooling => [Kogen.Proc]})
    |> assert_issue(fn issue -> assert issue.trigger == "Kogen.Harness.Opts" end)
  end

  test "Harness may call its declared Tooling dependency" do
    "defmodule Kogen.Harness.Developer do\n  def run(call), do: Kogen.Tooling.Tools.run(call)\nend\n"
    |> to_source_file("lib/kogen/harness/developer.ex")
    |> run_check(DomainReach, dependencies: %{Kogen.Harness => [Kogen.Tooling]})
    |> refute_issues()
  end
end
