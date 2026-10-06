defmodule Kogen.Checks.RailsBaselineTest do
  use Kogen.Testkit.Case

  alias Kogen.Checks
  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project
  alias Kogen.Testkit.Git

  for {linter, path} <- [{"rubocop", "Gemfile"}, {"standardrb", "app/old.rb"}] do
    test "#{linter} excuses only existing offences, including their number and message", %{
      tmp_dir: root
    } do
      repo = Git.create!(root)
      linter = unquote(linter)
      script = Path.join(repo, linter)
      File.write!(script, "#!/bin/sh\ncat offences.txt\nexit 1\n")
      spec = %CheckSpec{name: linter, argv: ["sh", script], timeout_ms: 1000}

      profile = %Project{
        root: repo,
        name: "lint",
        checks: [spec],
        fix: [],
        setup: [],
        diagnose: [],
        protected_paths: [],
        domains: %{}
      }

      output = Path.join(repo, "offences.txt")
      old = "  #{unquote(path)}:3:1: C: Style/Documentation: Missing documentation.\n"
      File.write!(output, old)
      assert {:ok, base} = run(profile, root, [], true)
      baseline = CheckBaseline.from_assessments(base.checks)
      File.write!(output, String.replace(old, ":3:", ":30:"))
      assert {:ok, %{status: :pass}} = run(profile, root, baseline)
      File.write!(output, old <> String.replace(old, ":3:", ":7:"))
      assert {:ok, %{status: {:fail, _}}} = run(profile, root, baseline)
      File.write!(output, String.replace(old, "Missing documentation.", "Different offence."))
      assert {:ok, %{status: {:fail, _}}} = run(profile, root, baseline)
    end
  end

  defp run(profile, root, baseline, record? \\ false) do
    run_dir = Path.join(root, "run-#{System.unique_integer([:positive])}")

    Checks.run_all(profile.root, profile, run_dir, Git.env(), Git.env(), %{
      check_baseline: baseline,
      baseline_run?: record?
    })
  end
end
