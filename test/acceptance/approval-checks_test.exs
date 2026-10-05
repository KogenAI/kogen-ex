defmodule Kogen.Acceptance.ApprovalChecksTest do
  use Kogen.Testkit.Case

  @moduletag :acceptance

  @git_env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_AUTHOR_NAME", "Kogen Test"},
    {"GIT_AUTHOR_EMAIL", "test@kogen.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Test"},
    {"GIT_COMMITTER_EMAIL", "test@kogen.invalid"}
  ]

  @intent """
  ---
  title: Probe
  domains: [app]
  size: small
  ---
  Probe the approval checks.

  ## Acceptance
  - A1: The probe passes.

  ## Verify
  - A1: test
  """

  @tag intent: "approval-checks/A1"
  test "a failing acceptance check refuses the approval", %{tmp_dir: tmp_dir} do
    repo = project!(tmp_dir, "FORBIDDEN")

    {output, status} = approve(repo)

    assert status != 0
    assert output =~ "no-forbidden"
    assert approval_ref(repo) == ""
  end

  @tag intent: "approval-checks/A2"
  test "passing acceptance checks record the approval and leave no files", %{tmp_dir: tmp_dir} do
    repo = project!(tmp_dir, "allowed")

    {_output, status} = approve(repo)

    assert status == 0
    assert approval_ref(repo) != ""
    refute File.exists?(Path.join(repo, "test/acceptance/probe_test.exs"))
    assert git(repo, ["status", "--porcelain"]) == ""
  end

  @tag intent: "approval-checks/A3"
  test "the path placeholder names the acceptance test location", %{tmp_dir: tmp_dir} do
    repo = project!(tmp_dir, "allowed")
    seen = Path.join(tmp_dir, "seen-path")

    write_project_yaml!(repo, [
      "[sh, -c, 'printf %s \"$1\" > #{seen}; cmp -s \"$1\" .kogen/acceptance/probe_test.exs', record, \"{path}\"]"
    ])

    commit!(repo)
    {_output, status} = approve(repo)

    assert status == 0
    assert File.read!(seen) == "test/acceptance/probe_test.exs"
  end

  @tag intent: "approval-checks/A4"
  test "a red project check is recorded and warned about at approval", %{tmp_dir: tmp_dir} do
    repo = project!(tmp_dir, "allowed")
    write!(repo, "lib/old.ex", "defmodule Old do\n def value,do: :old\nend\n")
    write!(repo, ".kogen/format-check.sh", format_check_script())

    write!(repo, ".kogen/project.yaml", """
    name: probe
    checks:
      - name: format
        argv: [sh, .kogen/format-check.sh]
        timeout_ms: 10000
    acceptance_checks:
      - name: acceptance-source-present
        argv: [test, -s, "{path}"]
        timeout_ms: 10000
    domains:
      app: [lib, test]
    """)

    commit!(repo)
    {output, status} = approve(repo)

    assert status == 0, output
    assert output =~ "Warning: configured checks are already red on the base"
    assert output =~ "format"
    assert output =~ "lib/old.ex"
    assert output =~ "fix the base first, or scope the check"
    assert approval_ref(repo) != ""

    assert {:ok, approval} = Kogen.State.approval(repo, "probe", Map.new(@git_env))
    assert [%{name: "format", status: :red}] = approval.check_baseline
  end

  test "runs project setup before acceptance checks and saves setup logs", %{tmp_dir: tmp_dir} do
    repo = project!(tmp_dir, "allowed")
    write!(repo, ".gitignore", ".kogen/setup-ready\n")
    write_project_yaml_with_setup!(repo, "[sh, -c, 'cp .kogen/setup-source .kogen/setup-ready']")
    write!(repo, ".kogen/setup-source", "ready\n")
    commit!(repo)

    {_output, status} = approve(repo)

    assert status == 0
    assert File.read!(Path.join(repo, ".kogen/setup-ready")) == "ready\n"
    assert [log] = setup_logs(tmp_dir)
    assert File.regular?(log)
  end

  test "setup failure is an environment failure with the log tail", %{tmp_dir: tmp_dir} do
    repo = project!(tmp_dir, "allowed")

    write_project_yaml_with_setup!(
      repo,
      "[sh, -c, 'echo approval-setup-diagnostic; exit 7']"
    )

    commit!(repo)

    {output, status} = approve(repo)

    assert status == 3
    assert output =~ "environment/setup_failed"
    assert output =~ "approval-setup-diagnostic"
    refute output =~ "check/acceptance_check_failed"
    assert approval_ref(repo) == ""
    assert [log] = setup_logs(tmp_dir)
    assert File.read!(log) =~ "approval-setup-diagnostic"
  end

  defp project!(tmp_dir, test_word) do
    repo = Kogen.Testkit.Git.create!(tmp_dir)
    write_project_yaml!(repo, [~s([sh, -c, '! grep -q FORBIDDEN "$1"', check, "{path}"])])
    write!(repo, ".kogen/intents/probe/intent.md", @intent)

    write!(repo, ".kogen/acceptance/probe_test.exs", """
    defmodule ProbeTest do
      use ExUnit.Case
      @tag intent: "probe/A1"
      test "probe", do: assert(#{inspect(test_word)})
    end
    """)

    commit!(repo)
    repo
  end

  defp write_project_yaml!(repo, [argv]) do
    write!(repo, ".kogen/project.yaml", """
    name: probe
    checks:
      - name: noop
        argv: [true]
        timeout_ms: 10000
    acceptance_checks:
      - name: no-forbidden
        argv: #{argv}
        timeout_ms: 10000
    domains:
      app: [lib, test]
    """)
  end

  defp write_project_yaml_with_setup!(repo, setup_argv) do
    write!(repo, ".kogen/project.yaml", """
    name: probe
    checks:
      - name: noop
        argv: [true]
        timeout_ms: 10000
    setup:
      - name: fixture
        argv: #{setup_argv}
        timeout_ms: 10000
    acceptance_checks:
      - name: setup-required
        argv: [test, -s, .kogen/setup-ready]
        timeout_ms: 10000
    domains:
      app: [lib, test]
    """)
  end

  defp write!(repo, relative, contents) do
    path = Path.join(repo, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp commit!(repo) do
    git(repo, ["add", "--all"])
    git(repo, ["-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "probe"])
  end

  defp approval_ref(repo) do
    repo
    |> git(["for-each-ref", "--format=%(objectname)", "refs/kogen/intents/probe"])
    |> String.trim()
  end

  defp approve(repo) do
    branch = repo |> git(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()

    intent = File.read!(Path.join(repo, ".kogen/intents/probe/intent.md"))
    hash = :sha256 |> :crypto.hash(intent) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    args = [
      "intent",
      "approve",
      "probe",
      hash,
      "--project",
      repo,
      "--origin",
      repo,
      "--base",
      branch,
      "--by",
      "acceptance test"
    ]

    elixir = System.find_executable("elixir")
    approval_tmp = Path.join(Path.dirname(repo), "approval-tmp")
    File.mkdir_p!(approval_tmp)

    {:ok, result} =
      Kogen.Proc.run(
        [elixir | child_args()] ++ ["-e", "Kogen.Kernel.CLI.main(#{inspect(args)})"],
        cd: repo,
        env:
          Map.merge(Map.new(@git_env), %{
            "PATH" => child_path(elixir),
            "HOME" => Path.dirname(repo),
            "TMPDIR" => approval_tmp
          }),
        timeout_ms: 60_000
      )

    {result.output_tail, result.exit_status}
  end

  defp setup_logs(tmp_dir) do
    Path.wildcard(
      Path.join([tmp_dir, "approval-tmp", "kogen-approval", "probe", "*", "logs", "setup-*.log"])
    )
  end

  defp format_check_script do
    """
    #!/bin/sh
    printf '** (Mix) mix format failed due to --check-formatted.\\nThe following files are not formatted:\\n  lib/old.ex\\n'
    exit 1
    """
  end

  defp git(repo, args) do
    Kogen.Testkit.Proc.cmd!("git", ["-C", repo | args], env: @git_env)
  end

  defp child_path(elixir) do
    mise = System.find_executable("mise")

    Enum.join(
      [
        Path.dirname(elixir),
        Path.join(:code.root_dir(), "bin"),
        Path.dirname(mise),
        "/usr/bin",
        "/bin"
      ],
      ":"
    )
  end

  defp child_args do
    Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
  end
end
