defmodule Kogen.Checks.ChecksTest do
  use Kogen.Testkit.Case

  alias Kogen.Checks
  alias Kogen.Checks.Ledger.Report
  alias Kogen.Checks.Ledger.Validation
  alias Kogen.Checks.LedgerCodec
  alias Kogen.Checks.LedgerRow
  alias Kogen.Contracts.AcceptanceItem
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Proc

  @git_env %{
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_AUTHOR_NAME" => "Kogen Test",
    "GIT_AUTHOR_EMAIL" => "test@kogen.invalid",
    "GIT_COMMITTER_NAME" => "Kogen Test",
    "GIT_COMMITTER_EMAIL" => "test@kogen.invalid"
  }

  test "runs checks, creates tree-bound receipts, and reports failing check names", %{
    tmp_dir: tmp_dir
  } do
    repo = Git.create!(tmp_dir)
    run_dir = Path.join(tmp_dir, "run")
    project = project([check("ok", ["/usr/bin/true"]), check("red", ["/usr/bin/false"])])

    assert {:ok, %{tree: tree, receipts: [pass, fail], status: {:fail, ["red"]}}} =
             Checks.run_all(repo, project, run_dir, @git_env)

    assert pass.tree == tree
    assert pass.check == "ok"
    assert pass.exit_status == 0
    assert byte_size(pass.log_sha256) == 64
    assert %DateTime{} = pass.at
    assert fail.check == "red"
    assert fail.exit_status != 0
    assert File.exists?(Path.join([run_dir, "logs", "check-1-ok.log"]))
    refute File.exists?(Path.join(repo, "logs"))
  end

  test "a check that changes candidate files fails as tree mutation", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    marker = Path.join(repo, "generated.txt")
    project = project([check("write", ["/usr/bin/touch", marker])])

    assert {:ok, %{status: {:fail, ["write"]}, feedback: feedback}} =
             Checks.run_all(repo, project, Path.join(tmp_dir, "run"), @git_env)

    assert feedback =~ "generated.txt"
    assert File.exists?(marker)
  end

  test "checks approved protected hashes and domain scope", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    protected = Path.join(repo, "mix.exs")
    File.write!(protected, "approved\n")
    git!(repo, ["add", "mix.exs"])
    git!(repo, ["commit", "--quiet", "-m", "protected fixture"])
    base_sha = git_output!(repo, ["rev-parse", "HEAD"])
    approved_sha = sha256(File.read!(protected))
    File.write!(protected, "changed\n")
    File.mkdir_p!(Path.join(repo, "lib/kogen/intent"))
    File.write!(Path.join(repo, "lib/kogen/intent/example.ex"), "module\n")

    assert {:ok, ["mix.exs"]} =
             Checks.protected_violations(repo, base_sha, %{"mix.exs" => approved_sha}, @git_env)

    intent = intent(["intent"])
    project = %{project([]) | domains: %{"intent" => ["lib/kogen/intent"]}}

    assert {:ok, ["mix.exs"]} =
             Checks.scope_violations(repo, base_sha, intent, project, [], @git_env)

    assert {:ok, []} =
             Checks.scope_violations(repo, base_sha, intent, project, ["mix.exs"], @git_env)
  end

  test "applies only the declared safe fix commands in order", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    first = Path.join(repo, "first.formatted")
    second = Path.join(repo, "second.formatted")

    project = %{
      project([])
      | fix: [
          check("first", ["/usr/bin/touch", first]),
          check("second", ["/usr/bin/touch", second])
        ]
    }

    assert {:ok, [%ProcResult{exit_status: 0}, %ProcResult{exit_status: 0}]} =
             Checks.fix(repo, project, Path.join(tmp_dir, "run"))

    assert File.exists?(first)
    assert File.exists?(second)
  end

  test "ledger codec round trips quotes, unicode and JSON control escapes" do
    row = %LedgerRow{tag: "slug/A1", test: "a \"quoted\" café\ncase", status: :passed}
    encoded = LedgerCodec.encode(row)
    assert encoded =~ "\\\"quoted\\\""
    assert {:ok, ^row} = LedgerCodec.decode(encoded)
  end

  test "a missing or empty ledger report is an environment failure", %{tmp_dir: tmp_dir} do
    assert {:error, %Failure{class: :environment, reason: :ledger_missing}} =
             Report.read(Path.join(tmp_dir, "missing.jsonl"))

    empty = Path.join(tmp_dir, "empty.jsonl")
    File.write!(empty, "\n")
    assert {:error, %Failure{reason: :ledger_empty}} = Report.read(empty)
  end

  test "candidate ledger ignores other slugs and rejects missing, unknown, failed and skipped ids" do
    items = [acceptance_item("A1", :test), acceptance_item("A2", :test_keep)]

    rows = [
      ledger("other/A1", :failed),
      ledger("slug/A1", :passed),
      ledger("slug/A2", :skipped),
      ledger("slug/A9", :passed)
    ]

    assert Validation.candidate(items, rows, 2, "slug") == ["slug/A9", "A2", "suite"]

    assert Validation.candidate(
             items,
             [ledger("slug/A1", :passed), ledger("slug/A2", :passed)],
             0,
             "slug"
           ) == []

    assert Validation.candidate(items, [ledger("slug/A1", :passed)], 0, "slug") == ["A2"]
  end

  test "red on base requires change tests to fail and keep tests to pass" do
    items = [acceptance_item("A1", :test), acceptance_item("A2", :test_keep)]

    assert :ok =
             Validation.base(
               items,
               [ledger("slug/A1", :failed), ledger("slug/A2", :passed)],
               "slug"
             )

    assert {:error, %Failure{reason: :green_on_base}} =
             Validation.base(
               items,
               [ledger("slug/A1", :passed), ledger("slug/A2", :passed)],
               "slug"
             )

    assert {:error, %Failure{reason: :keep_not_green_on_base}} =
             Validation.base(
               items,
               [ledger("slug/A1", :failed), ledger("slug/A2", :failed)],
               "slug"
             )
  end

  @tag :io
  test "external ExUnit formatter writes JSONL for a tiny generated project", %{tmp_dir: tmp_dir} do
    fixture = candidate_project(tmp_dir)
    rows = candidate_rows(fixture, tmp_dir)
    assert_candidate_ledger(rows)
    assert_base_red(fixture, tmp_dir)
    assert_acceptance_api(fixture, tmp_dir)
  end

  defp candidate_project(tmp_dir) do
    project_dir = Git.create!(Path.join(tmp_dir, "tiny-project-area"))
    formatter = Path.expand("../../priv/ledger/kogen_ledger_formatter.ex", __DIR__)
    runner = Path.join(tmp_dir, "run-mix-test")
    File.mkdir_p!(Path.join(project_dir, "test/acceptance"))
    File.mkdir_p!(Path.join(project_dir, "lib"))
    File.write!(Path.join(project_dir, ".gitignore"), "_build/\ndeps/\n")
    File.write!(Path.join(project_dir, "mix.exs"), tiny_mix_project())
    File.write!(Path.join(project_dir, "test/test_helper.exs"), "ExUnit.start()\n")
    File.write!(Path.join(project_dir, "lib/demo.ex"), demo_source(":new"))

    File.write!(
      Path.join([project_dir, "test", "acceptance", "slug_test.exs"]),
      tiny_test_source()
    )

    File.write!(
      Path.join([project_dir, "test", "acceptance", "other_test.exs"]),
      other_test_source()
    )

    git!(project_dir, ["add", "--all"])
    git!(project_dir, ["commit", "--quiet", "-m", "tiny test project"])
    %{project_dir: project_dir, formatter: formatter, runner: runner}
  end

  defp candidate_rows(fixture, tmp_dir) do
    report = Path.join(tmp_dir, "ledger.jsonl")
    run_formatter(fixture.project_dir, fixture.formatter, report, fixture.runner, [])
    {:ok, rows} = Report.read(report)
    rows
  end

  defp assert_candidate_ledger(rows) do
    statuses = Map.new(rows, &{&1.tag, &1.status})
    assert statuses["other/A1"] == :passed
    assert statuses["slug/A1"] == :passed
    assert statuses["slug/A2"] == :failed
    assert statuses["slug/A3"] == :skipped
    assert statuses["slug/A9"] == :passed

    items = [
      acceptance_item("A1", :test),
      acceptance_item("A2", :test),
      acceptance_item("A3", :test_keep)
    ]

    failures = Validation.candidate(items, rows, 2, "slug")
    assert MapSet.new(failures) == MapSet.new(["A2", "A3", "slug/A9", "suite"])
  end

  defp assert_base_red(fixture, tmp_dir) do
    base_dir = Git.create!(Path.join(tmp_dir, "base-project-area"))
    File.mkdir_p!(Path.join(base_dir, "test/acceptance"))
    File.mkdir_p!(Path.join(base_dir, "lib"))
    File.write!(Path.join(base_dir, ".gitignore"), "_build/\ndeps/\n")
    File.write!(Path.join(base_dir, "mix.exs"), tiny_mix_project())
    File.write!(Path.join(base_dir, "test/test_helper.exs"), "ExUnit.start()\n")
    File.write!(Path.join(base_dir, "lib/demo.ex"), demo_source(":old"))
    File.write!(Path.join([base_dir, "test", "acceptance", "slug_test.exs"]), tiny_test_source())
    git!(base_dir, ["add", "--all"])
    git!(base_dir, ["commit", "--quiet", "-m", "base test project"])
    report = Path.join(tmp_dir, "base-ledger.jsonl")

    run_formatter(base_dir, fixture.formatter, report, fixture.runner, [
      "test/acceptance/slug_test.exs"
    ])

    assert {:ok, [%LedgerRow{tag: "slug/A1", status: :failed} = row]} = Report.read(report)
    assert :ok = Validation.base([acceptance_item("A1", :test)], [row], "slug")
  end

  defp assert_acceptance_api(fixture, tmp_dir) do
    intent = intent(["checks"])

    case Checks.acceptance(fixture.project_dir, intent, Path.join(tmp_dir, "acceptance-run")) do
      {:ok, %{status: :pass, ledger: [%LedgerRow{tag: "slug/A1", status: :passed}]}} -> :ok
      {:error, %Failure{class: :environment, reason: :tool_missing}} -> :ok
      result -> flunk("unexpected acceptance result: #{inspect(result)}")
    end
  end

  defp project(checks),
    do: %Project{
      root: "/tmp/project",
      name: "test-project",
      checks: checks,
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{}
    }

  defp check(name, argv), do: %CheckSpec{name: name, argv: argv, timeout_ms: 5_000}

  defp intent(domains),
    do: %Intent{
      slug: "slug",
      title: "Test intent",
      size: :small,
      brief: "Exercise a scoped change.",
      acceptance: [acceptance_item("A1", :test)],
      domains: domains,
      notes: nil,
      path: "/tmp/slug/intent.md",
      sha256: "hash"
    }

  defp acceptance_item(id, verify),
    do: %AcceptanceItem{id: id, text: id, verify: verify, domain: nil}

  defp ledger(tag, status), do: %LedgerRow{tag: tag, test: "test", status: status}

  defp git!(repo, args) do
    _output = Proc.cmd!("git", ["-C", repo | args], env: Map.to_list(@git_env))
    :ok
  end

  defp git_output!(repo, args) do
    repo
    |> then(&Proc.cmd!("git", ["-C", &1 | args], env: Map.to_list(@git_env)))
    |> String.trim()
  end

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  defp run_formatter(project_dir, formatter, report, runner, test_args) do
    preload =
      "Code.require_file(#{inspect(formatter)}); Code.ensure_loaded!(KogenLedgerFormatter)"

    argv = [
      "elixir",
      "-e",
      preload,
      "-S",
      "mix",
      "test",
      "--formatter",
      "KogenLedgerFormatter",
      "--formatter",
      "ExUnit.CLIFormatter" | test_args
    ]

    File.write!(runner, "#!/bin/sh\n#{shell_command(argv)} >/dev/null 2>&1\nexit 0\n")
    File.chmod!(runner, 0o700)
    Proc.cmd!(runner, [], cd: project_dir, env: [{"KOGEN_LEDGER_REPORT", report}])
  end

  defp shell_command(argv) do
    Enum.map_join(argv, " ", fn arg -> "'" <> String.replace(arg, "'", "'\\''") <> "'" end)
  end

  defp demo_source(value) do
    """
    defmodule Demo do
      def value, do: #{value}
    end
    """
  end

  defp tiny_mix_project do
    """
    defmodule TinyLedger.MixProject do
      use Mix.Project
      def project, do: [app: :tiny_ledger, version: "0.1.0", elixir: "~> 1.20"]
      def application, do: [extra_applications: [:logger]]
    end
    """
  end

  defp tiny_test_source do
    """
    defmodule TinyLedger.AcceptanceTest do
      use ExUnit.Case, async: true
      @tag intent: "slug/A1"
      test "passes" do
        assert Demo.value() == :new
      end
    end
    """
  end

  defp other_test_source do
    """
    defmodule TinyLedger.OtherIntentTest do
      use ExUnit.Case, async: true
      @tag intent: "other/A1"
      test "belongs to another intent" do
        assert true
      end

      @tag intent: "slug/A2"
      test "fails on the candidate" do
        assert false
      end

      @tag intent: "slug/A3"
      @tag :skip
      test "is skipped" do
        assert true
      end

      @tag intent: "slug/A9"
      test "has an unknown id" do
        assert true
      end
    end
    """
  end
end
