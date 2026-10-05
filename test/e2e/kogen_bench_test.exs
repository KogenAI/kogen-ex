defmodule Kogen.E2e.KogenBenchTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Testkit.Git

  @moduletag :e2e

  test "copies failed candidate diffs into the benchmark output and usage receipt", %{
    tmp_dir: tmp_dir
  } do
    {status, output, paths} = run_bench!(tmp_dir, %{})
    out_dir = paths.out_dir

    assert status == 1, output
    assert File.read!(Path.join(out_dir, "candidate.diff")) =~ "candidate implementation"
    assert File.read!(Path.join(out_dir, "final.diff")) == ""

    usage = out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()
    assert {usage["landed"], usage["best_candidate"]} == {false, false}

    assert [
             %{
               "attempt" => "builder",
               "file" => "candidate.diff",
               "red_checks" => [%{"name" => "tests"}]
             }
           ] =
             usage["candidate_diffs"]
  end

  test "copies the shape and Build request journals and keeps partial usage of a failed run", %{
    tmp_dir: tmp_dir
  } do
    {status, output, paths} = run_bench!(tmp_dir, %{})
    assert status == 1, output

    assert paths.out_dir
           |> Path.join("requests.jsonl")
           |> File.read!()
           |> String.split("\n", trim: true) ==
             [
               ~s({"stage":"shape","outcome":"ok","retries":0}),
               ~s({"stage":"develop","outcome":"ok","retries":0}),
               ~s({"stage":"develop","outcome":"timeout","retries":0})
             ]

    usage = paths.out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()

    assert usage["total"]["tokens"] == %{
             "input" => 300,
             "cached_input" => 0,
             "output" => 30,
             "reasoning" => 0
           }

    assert %{"partial" => true} = Enum.find(usage["stages"], &(&1["stage"] == "develop"))
  end

  test "writes a request journal even when the benchmark stops before the Build", %{
    tmp_dir: tmp_dir
  } do
    {status, output, paths} = run_bench!(tmp_dir, %{"FAKE_KOGEN_SHAPE_EXIT" => "9"})
    assert status == 9, output

    assert File.read!(Path.join(paths.out_dir, "requests.jsonl")) ==
             ~s({"stage":"shape","outcome":"ok","retries":0}\n)
  end

  test "grades a Build's best candidate branch as the final diff when it did not land", %{
    tmp_dir: tmp_dir
  } do
    {status, output, paths} = run_bench!(tmp_dir, %{"FAKE_KOGEN_BEST" => "1"})

    assert status == 0, output
    final = File.read!(Path.join(paths.out_dir, "final.diff"))
    assert final =~ "+++ b/best.txt"
    assert final =~ "+best candidate implementation"
    assert File.read!(Path.join(paths.work_dir, "best.txt")) == "best candidate implementation\n"

    usage = paths.out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()
    assert usage["recipe"] == "ladder"
    assert {usage["landed"], usage["best_candidate"]} == {false, true}
    assert usage["best_candidate_detail"]["branch"] == "kogen/task"

    assert File.read!(Path.join(paths.out_dir, "log.txt")) =~
             "grading its best candidate kogen/task"
  end

  test "accepts the ladder-diverse recipe and records it", %{tmp_dir: tmp_dir} do
    {_status, output, paths} = run_bench!(tmp_dir, %{"KOGEN_BENCH_RECIPE" => "ladder-diverse"})

    usage = paths.out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()
    assert usage["recipe"] == "ladder-diverse", output
  end

  test "turns on the edge probe for a +edge ladder recipe or KOGEN_BENCH_EDGE_TESTS=1", %{
    tmp_dir: tmp_dir
  } do
    copy = Path.join(tmp_dir, "project.yaml")

    env = %{"KOGEN_BENCH_RECIPE" => "ladder-luna+edge", "FAKE_KOGEN_PROJECT_COPY" => copy}
    {_status, output, paths} = run_bench!(subdir(tmp_dir, "suffix"), env)
    usage = paths.out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()
    assert {usage["recipe"], usage["edge_tests"]} == {"ladder-luna", true}, output
    assert File.read!(copy) =~ ~s(build:\n  recipe: "ladder-luna"\n  edge_tests: true\n)

    env = %{"KOGEN_BENCH_EDGE_TESTS" => "1"}
    {_status, output, paths} = run_bench!(subdir(tmp_dir, "knob"), env)
    usage = paths.out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()
    assert {usage["recipe"], usage["edge_tests"]} == {"ladder", true}, output

    env = %{"KOGEN_BENCH_EDGE_TESTS" => "1", "KOGEN_BENCH_RECIPE" => "direct"}
    {status, output, _paths} = run_bench!(subdir(tmp_dir, "direct"), env)
    assert status == 2
    assert output =~ "KOGEN_BENCH_EDGE_TESTS=1 needs a ladder recipe"
  end

  defp subdir(tmp_dir, name) do
    path = Path.join(tmp_dir, name)
    File.mkdir_p!(path)
    path
  end

  defp run_bench!(tmp_dir, extra_env) do
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
               env:
                 Map.merge(
                   %{
                     "HOME" => home,
                     "KOGEN_BIN" => fake_kogen,
                     "PATH" => runtime.base_env["PATH"],
                     "TMPDIR" => tmp_dir
                   },
                   extra_env
                 ),
               timeout_ms: 120_000
             )

    {status, output, %{out_dir: out_dir, work_dir: work_dir}}
  end
end
