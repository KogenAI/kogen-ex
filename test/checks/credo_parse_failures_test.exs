defmodule Kogen.Checks.CredoParseFailuresTest do
  use Kogen.Testkit.Case

  alias Kogen.Checks
  alias Kogen.Checks.Feedback
  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.CheckOutput
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project
  alias Kogen.Testkit.Git

  @root Path.expand("../..", __DIR__)

  test "actual Credo timeouts and parser failures cannot produce a complete green receipt", %{
    tmp_dir: tmp
  } do
    repo = Git.create!(tmp)
    config = Path.join(tmp, "credo.exs")

    File.write!(config, """
    %{configs: [%{name: "default", parse_timeout: 1, checks: %{enabled: [], disabled: []}}]}
    """)

    for {name, source, rule} <- [
          {"slow.ex",
           "defmodule Slow do\n" <> String.duplicate("def f, do: :ok\n", 50_000) <> "end",
           "parse_timeout"},
          {"invalid.ex", "defmodule Invalid do\ndef broken(\nend", "parse_failure"}
        ] do
      path = Path.join(tmp, name)
      File.write!(path, source)

      if rule == "parse_failure" do
        File.write!(
          config,
          "%{configs: [%{name: \"default\", parse_timeout: 30_000, checks: %{enabled: [], disabled: []}}]}"
        )
      end

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Credo.run(["--strict", "--config-file", config, path])
        end)

      assert output =~ name

      spec = %CheckSpec{
        name: "credo",
        argv: ["cat", Path.join(tmp, "output.log")],
        timeout_ms: 5_000
      }

      File.write!(Enum.at(spec.argv, 1), output)
      assert {:ok, result} = run(repo, tmp, spec, [])
      assert result.status == {:fail, ["credo"]}
      assert result.feedback =~ rule
      assert result.feedback =~ name
      assert [%{analysis: :incomplete, exit_status: 0, duration_ms: duration}] = result.receipts
      assert is_integer(duration) and duration >= 0
      assert [finding] = hd(result.checks).findings
      assert %Kogen.Contracts.Finding{rule: ^rule, line: nil, col: nil} = finding
      assert is_binary(finding.id)
      baseline = CheckBaseline.from_assessments(result.checks)
      assert {:ok, excused} = run(repo, tmp, spec, baseline)
      assert excused.status == :pass
      assert excused.warnings != []
    end
  end

  test "all skipped files survive a clipped output tail and new skipped files fail", %{
    tmp_dir: tmp
  } do
    repo = Git.create!(tmp)
    log = Path.join(tmp, "credo.log")

    output =
      "info: Some source files were not parsed in the time allotted:\n  1) lib/a.ex\n  2) lib/b.ex\n"

    File.write!(log, output <> String.duplicate("fully analyzed other file\n", 2_000))
    spec = %CheckSpec{name: "full", argv: ["cat", log], timeout_ms: 5_000}
    assert {:ok, result} = run(repo, tmp, spec, [])
    assert result.feedback =~ "lib/a.ex"
    assert result.feedback =~ "lib/b.ex"
    assert [%{analysis: :incomplete}] = result.receipts
    baseline = CheckBaseline.from_assessments(result.checks)
    File.write!(log, output <> "  3) lib/c.ex\n")
    assert {:ok, changed} = run(repo, tmp, spec, baseline)
    assert changed.status == {:fail, ["full"]}
    assert changed.feedback =~ "lib/c.ex"

    clean =
      Feedback.analyze(%CheckOutput{
        name: "credo",
        argv: ["mix", "credo"],
        exit_status: 0,
        timed_out: false,
        output: "No issues found",
        log_path: nil,
        workdir: repo
      })

    assert clean.exit_level == 0
    assert clean.findings == []
  end

  test "the approved Credo configuration stays protected when the Intent changes the gate" do
    assert {:ok, project} = Kogen.Project.load(@root)
    assert ".credo.exs" in Kogen.Project.protected_patterns(project, true, [".credo.exs"])
  end

  defp run(repo, tmp, spec, baseline) do
    project = %Project{
      root: repo,
      name: "credo-parse",
      checks: [spec],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{}
    }

    dir = Path.join(tmp, "run-#{System.unique_integer([:positive])}")
    Checks.run_all(repo, project, dir, Git.env(), Git.env(), %{check_baseline: baseline})
  end
end
