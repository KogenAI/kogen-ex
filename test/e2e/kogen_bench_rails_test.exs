defmodule Kogen.E2e.KogenBenchRailsTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Project
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Rails, as: RailsFixture

  @moduletag :e2e
  @moduletag timeout: 300_000
  @moduletag skip: RailsFixture.unavailable_reason()

  test "Rails benchmark setup preserves the public patch and installs its bundle without deps", %{
    tmp_dir: root
  } do
    work = RailsFixture.project!(Path.join(root, "work"))
    task = Path.join(root, "rails-task")
    capture = Path.join(root, "capture")
    out = Path.join(root, "out")
    File.mkdir_p!(task)
    File.mkdir_p!(capture)
    File.write!(Path.join(task, "prompt.md"), "Change the greeting.\n")
    File.write!(Path.join(work, "config/fixture.txt"), "before\n")
    Git.git!(work, ["add", "--all"])
    Git.git!(work, ["commit", "--quiet", "-m", "Add patch target"])

    patch = """
    diff --git a/config/fixture.txt b/config/fixture.txt
    --- a/config/fixture.txt
    +++ b/config/fixture.txt
    @@ -1 +1 @@
    -before
    +patched
    """

    File.write!(Path.join(task, "environment.patch"), patch)

    File.write!(
      Path.join(task, "task.json"),
      :json.encode(%{
        "setup" => "git apply environment.patch",
        "env" => %{
          "GEM_HOME" => Path.join(root, "gem-home"),
          "GEM_PATH" => Path.join(root, "gem-home")
        }
      })
    )

    home = Path.join(root, "home")
    File.mkdir_p!(home)
    runtime = RailsFixture.runtime!(work, home)
    ruby_bin = runtime.base_env["PATH"] |> String.split(":") |> hd()
    fake = Path.join(root, "fake-kogen")
    File.write!(fake, fake_kogen())
    File.chmod!(fake, 0o755)

    env =
      Map.merge(runtime.base_env, %{
        "PATH" => ruby_bin <> ":/usr/bin:/bin",
        "KOGEN_BIN" => fake,
        "KOGEN_BENCH_CAPTURE" => capture,
        "KOGEN_BENCH_INTENT_SOURCE" => "raw",
        "KOGEN_BENCH_DEPS_SOURCE" => Path.join(root, "does-not-exist"),
        "TMPDIR" => root
      })

    assert {:ok, %ProcResult{exit_status: 1}} =
             Proc.run(
               [
                 "/bin/sh",
                 Path.expand("../../bin/kogen-bench", __DIR__),
                 task,
                 work,
                 out
               ],
               cd: root,
               env: env,
               timeout_ms: 180_000
             )

    assert File.read!(Path.join(capture, "config/fixture.txt")) == "patched\n"
    assert {:ok, project} = Project.load(capture)
    assert Enum.map(project.checks, & &1.name) == ["tests"]
    assert "rails" in hd(project.checks).argv
    refute "mix" in hd(project.checks).argv
    refute "mise" in hd(project.checks).argv
    assert Enum.any?(project.setup, &(&1.name == "bundle-install"))
    assert project.setup_outputs == []
    assert project.env["GEM_HOME"] == Path.join(root, "gem-home")
    assert File.exists?(Path.join(capture, "acceptance_test.rb"))
    refute File.exists?(Path.join(capture, "deps"))
    assert File.read!(Path.join(capture, "rails-tests.log")) =~ "0 failures, 0 errors"
    assert Git.git!(work, ["status", "--porcelain"]) == ""
    assert File.read!(Path.join(work, "config/fixture.txt")) == "before\n"
  end

  defp fake_kogen do
    """
    #!/usr/bin/env python3
    import json, os, pathlib, shutil, subprocess, sys
    args = sys.argv[1:]
    if args[0] == "version":
        sys.exit(1)
    if args[0] == "approve":
        root = pathlib.Path(args[args.index("--project") + 1])
        capture = pathlib.Path(os.environ["KOGEN_BENCH_CAPTURE"])
        env = os.environ.copy()
        env["BUNDLE_PATH"] = ".bundle/gems"
        env["BUNDLE_USER_HOME"] = str(root / ".bundle/user")
        env["BUNDLE_APP_CONFIG"] = str(root / ".bundle")
        section = ""
        for line in (root / ".kogen/project.yaml").read_text().splitlines():
            if line and not line.startswith(" "):
                section = line.split(":", 1)[0]
            if section == "setup" and "argv: " in line:
                subprocess.run(json.loads(line.split("argv: ", 1)[1]), cwd=root, env=env, check=True)
        result = subprocess.run(["bundle", "exec", "rails", "test"], cwd=root, env=env, capture_output=True, text=True)
        if result.returncode:
            print(result.stdout + result.stderr)
            sys.exit(result.returncode)
        shutil.copytree(root / ".kogen", capture / ".kogen", dirs_exist_ok=True)
        shutil.copytree(root / "config", capture / "config", dirs_exist_ok=True)
        shutil.copyfile(root / "Gemfile", capture / "Gemfile")
        shutil.copyfile(root / ".kogen/acceptance/rails-task_test.rb", capture / "acceptance_test.rb")
        (capture / "rails-tests.log").write_text(result.stdout)
    elif args[:2] == ["build", "show"]:
        print('{"status":"failed","attempts":[],"candidate_diffs":[],"escalations":[],"model_stages":[],"phase_timings":[]}')
    elif args[0] == "build":
        sys.exit(1)
    else:
        sys.exit(90)
    """
  end
end
