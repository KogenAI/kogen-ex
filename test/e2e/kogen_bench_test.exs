defmodule Kogen.E2e.KogenBenchTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Testkit.Git

  @moduletag :e2e

  test "copies failed candidate diffs into the benchmark output and usage receipt", %{
    tmp_dir: tmp_dir
  } do
    task_dir = Path.join(tmp_dir, "task")
    out_dir = Path.join(tmp_dir, "out")
    fake_kogen = Path.join(tmp_dir, "fake-kogen")
    fake_kogen_fixture = Path.expand("../fixtures/kogen_bench/fake_kogen.txt", __DIR__)
    work_dir = Git.create!(Path.join(tmp_dir, "work"))

    File.mkdir_p!(task_dir)
    File.write!(Path.join(task_dir, "prompt.md"), "Implement the fixture request.\n")
    File.write!(Path.join(task_dir, "task.json"), ~s({"env": {}}\n))
    File.cp!(fake_kogen_fixture, fake_kogen)
    File.chmod!(fake_kogen, 0o755)

    script = Path.expand("../../bin/kogen-bench", __DIR__)
    assert {:ok, runtime} = Kogen.Kernel.runtime()

    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)

    assert {:ok, %ProcResult{exit_status: status, output_tail: output}} =
             Proc.run(["/bin/sh", script, task_dir, work_dir, out_dir],
               cd: tmp_dir,
               env: %{
                 "HOME" => home,
                 "KOGEN_BIN" => fake_kogen,
                 "PATH" => runtime.base_env["PATH"],
                 "TMPDIR" => tmp_dir
               },
               timeout_ms: 120_000
             )

    assert status == 1, output
    assert File.read!(Path.join(out_dir, "candidate.diff")) =~ "candidate implementation"
    assert File.read!(Path.join(out_dir, "final.diff")) == ""

    usage = out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()

    assert [
             %{
               "attempt" => "builder",
               "file" => "candidate.diff",
               "red_checks" => [%{"name" => "tests"}]
             }
           ] =
             usage["candidate_diffs"]
  end
end
