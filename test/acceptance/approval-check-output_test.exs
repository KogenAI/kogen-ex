defmodule Kogen.Acceptance.ApprovalCheckOutputTest do
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

  @tag intent: "approval-check-output/A1"
  test "a failing check shows its output tail", %{tmp_dir: tmp_dir} do
    repo = project!(tmp_dir, "allowed")

    write_project_yaml!(repo, [
      "[sh, -c, 'echo first-line; echo explain-the-failure-here; exit 3']"
    ])

    commit!(repo)

    {output, status} = approve(repo)

    assert status != 0
    assert output =~ "explain-the-failure-here"
  end

  @tag intent: "approval-check-output/A2"
  test "a timed out check is reported as a timeout", %{tmp_dir: tmp_dir} do
    repo = project!(tmp_dir, "allowed")
    write_project_yaml!(repo, ["[sleep, '30']"], 200)
    commit!(repo)

    {output, status} = approve(repo)

    assert status != 0
    assert output =~ "no-forbidden"
    assert output =~ ~r/timed out|timeout/i
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

  defp write_project_yaml!(repo, [argv], timeout_ms \\ 10_000) do
    write!(repo, ".kogen/project.yaml", """
    name: probe
    checks:
      - name: noop
        argv: [true]
        timeout_ms: 10000
    acceptance_checks:
      - name: no-forbidden
        argv: #{argv}
        timeout_ms: #{timeout_ms}
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

  defp approve(repo) do
    branch = repo |> git(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()

    args = [
      "intent",
      "approve",
      "probe",
      "--project",
      repo,
      "--origin",
      repo,
      "--base",
      branch,
      "--yes",
      "--by",
      "acceptance test"
    ]

    elixir = System.find_executable("elixir")

    {:ok, result} =
      Kogen.Proc.run(
        [elixir | child_args()] ++ ["-e", "Kogen.Kernel.CLI.main(#{inspect(args)})"],
        cd: repo,
        env:
          Map.merge(Map.new(@git_env), %{
            "PATH" => child_path(elixir),
            "HOME" => Path.dirname(repo)
          }),
        timeout_ms: 60_000
      )

    {result.output_tail, result.exit_status}
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
