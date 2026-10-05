defmodule Kogen.Acceptance.LadderIsDefaultTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Testkit.Git

  @moduletag :acceptance
  @project_root Path.expand("../..", __DIR__)
  @recipes [
    "ladder",
    "ladder-luna",
    "ladder-sol-medium",
    "staged",
    "plan-shell",
    "direct",
    "direct-shell",
    "direct-escalate",
    "escalate-shell"
  ]

  @tag intent: "ladder-is-default/A1"
  test "omitted project and machine recipes default to ladder", %{tmp_dir: tmp_dir} do
    project_root = write_project!(Path.join(tmp_dir, "project"), "name: probe\nchecks: []\n")
    assert {:ok, project} = Kogen.Project.load(project_root)

    home = Path.join(tmp_dir, "home")
    machine_config = Path.join([home, ".kogen", "config.yaml"])
    File.mkdir_p!(Path.dirname(machine_config))
    File.write!(machine_config, "build:\n  roles:\n    builder:\n      model: machine-model\n")

    assert {:ok, machine} = Kogen.Project.load_machine_build_settings(home)
    assert machine.recipe == nil
    assert Kogen.Project.effective_build_settings(machine, project.build).recipe == "ladder"

    empty_home = Path.join(tmp_dir, "empty-home")
    assert {:ok, nil} = Kogen.Project.load_machine_build_settings(empty_home)
    assert Kogen.Project.effective_build_settings(nil, project.build).recipe == "ladder"
  end

  @tag intent: "ladder-is-default/A2"
  test "explicit project and machine recipes retain their precedence" do
    machine = %{recipe: "direct-shell", roles: %{}}
    project = %{recipe: "direct", roles: %{}}

    assert Kogen.Project.effective_build_settings(machine, project).recipe == "direct"
    assert Kogen.Project.effective_build_settings(machine, nil).recipe == "direct-shell"
  end

  @tag intent: "ladder-is-default/A3"
  test "the benchmark runner defaults to ladder", %{tmp_dir: tmp_dir} do
    usage = run_benchmark!(Path.join(tmp_dir, "default"), nil)
    assert usage["recipe"] == "ladder"
  end

  @tag intent: "ladder-is-default/A4"
  test "the benchmark runner honors an explicit recipe, including single-model ladders", %{
    tmp_dir: tmp_dir
  } do
    for recipe <- ["direct-shell", "ladder-luna", "ladder-sol-medium"] do
      usage = run_benchmark!(Path.join(tmp_dir, recipe), recipe)
      assert usage["recipe"] == recipe
    end
  end

  @tag intent: "ladder-is-default/A5"
  test "Kogen's project configuration keeps its explicit plan-shell recipe" do
    assert {:ok, project} = Kogen.Project.load(@project_root)
    assert project.build.recipe == "plan-shell"
  end

  @tag intent: "ladder-is-default/A6"
  test "every supported recipe, including the ladders, is selectable", %{tmp_dir: tmp_dir} do
    project_root = Path.join(tmp_dir, "project")

    for recipe <- @recipes do
      write_project!(project_root, "name: probe\nchecks: []\nbuild:\n  recipe: #{recipe}\n")
      assert {:ok, project} = Kogen.Project.load(project_root)
      assert project.build.recipe == recipe
    end
  end

  defp run_benchmark!(root, recipe) do
    paths = benchmark_fixture!(root)
    assert {:ok, runtime} = Kogen.Kernel.runtime()
    env = benchmark_env(paths, runtime, recipe)
    run_benchmark_process!(paths, root, env)
    paths.out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()
  end

  defp benchmark_fixture!(root) do
    paths = %{
      task_dir: Path.join(root, "task"),
      work_dir: Git.create!(Path.join(root, "work")),
      out_dir: Path.join(root, "out"),
      home: Path.join(root, "home"),
      fake_kogen: Path.join(root, "fake-kogen")
    }

    File.mkdir_p!(paths.task_dir)
    File.mkdir_p!(paths.home)
    File.write!(Path.join(paths.task_dir, "prompt.md"), "Implement the task.\n")
    task_json = IO.iodata_to_binary(:json.encode(%{"env" => %{}}))
    File.write!(Path.join(paths.task_dir, "task.json"), task_json)

    fixture = Path.join([@project_root, "test", "fixtures", "kogen_bench", "fake_kogen.txt"])
    File.cp!(fixture, paths.fake_kogen)
    File.chmod!(paths.fake_kogen, 0o755)
    paths
  end

  defp benchmark_env(paths, runtime, recipe) do
    env = %{
      "HOME" => paths.home,
      "KOGEN_BIN" => paths.fake_kogen,
      "PATH" => runtime.base_env["PATH"],
      "TMPDIR" => Path.dirname(paths.task_dir)
    }

    if recipe, do: Map.put(env, "KOGEN_BENCH_RECIPE", recipe), else: env
  end

  defp run_benchmark_process!(paths, root, env) do
    script = Path.join([@project_root, "bin", "kogen-bench"])

    assert {:ok, %ProcResult{exit_status: 1}} =
             Proc.run(["/bin/sh", script, paths.task_dir, paths.work_dir, paths.out_dir],
               cd: root,
               env: env,
               timeout_ms: 120_000
             )
  end

  defp write_project!(root, source) do
    path = Path.join(root, ".kogen/project.yaml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    root
  end
end
