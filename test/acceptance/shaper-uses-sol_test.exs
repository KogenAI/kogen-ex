defmodule Kogen.Acceptance.ShaperUsesSolTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Kernel.BuildConfig
  alias Kogen.Proc
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Proc, as: TestProc

  @moduletag :acceptance
  @bench_slug "shaper-bench-settings"

  @tag intent: "shaper-uses-sol/A1"
  test "shaping defaults to Sol high even when the builder uses Luna max" do
    roles = %{builder: %{model: "gpt-6-luna", effort: "max"}}

    assert BuildConfig.shape_settings(roles) == {"gpt-6.1-sol", "high"}

    assert BuildConfig.shape_settings(Map.put(roles, :shaper, %{effort: "low"})) ==
             {"gpt-6.1-sol", "low"}

    assert BuildConfig.shape_settings(Map.put(roles, :shaper, %{model: "experiment"})) ==
             {"experiment", "high"}
  end

  @tag intent: "shaper-uses-sol/A2"
  test "machine shaper settings apply and project fields override them", %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(Path.join(home, ".kogen"))

    File.write!(Path.join([home, ".kogen", "config.yaml"]), """
    build:
      roles:
        builder:
          model: gpt-6-luna
          effort: max
        shaper:
          model: machine-shaper
          effort: low
    """)

    assert {:ok, machine} = Kogen.Project.load_machine_build_settings(home)
    assert BuildConfig.shape_settings(machine.roles) == {"machine-shaper", "low"}

    project_root = Path.join(tmp_dir, "project")
    File.mkdir_p!(Path.join(project_root, ".kogen"))

    File.write!(Path.join([project_root, ".kogen", "project.yaml"]), """
    name: shaper-settings
    checks: []
    build:
      roles:
        shaper:
          model: project-shaper
    """)

    assert {:ok, project} = Kogen.Project.load(project_root)
    effective = Kogen.Project.effective_build_settings(machine, project.build)

    assert BuildConfig.shape_settings(effective.roles) == {"project-shaper", "low"}
  end

  @tag intent: "shaper-uses-sol/A3"
  test "benchmark shape environment variables populate the generated shaper role", %{
    tmp_dir: tmp_dir
  } do
    paths = benchmark_fixture(tmp_dir)
    assert {:ok, runtime} = Kogen.Kernel.runtime()

    env = %{
      "HOME" => Path.join(tmp_dir, "home"),
      "KOGEN_BIN" => paths.fake_kogen,
      "KOGEN_BENCH_CAPTURE" => paths.capture,
      "KOGEN_BENCH_SHAPE_MODEL" => "benchmark-shaper",
      "KOGEN_BENCH_SHAPE_EFFORT" => "benchmark-effort",
      "PATH" => runtime.base_env["PATH"],
      "TMPDIR" => tmp_dir
    }

    script = Path.expand("../../bin/kogen-bench", __DIR__)

    assert {:ok, %ProcResult{exit_status: 1}} =
             Proc.run(["/bin/sh", script, paths.task_dir, paths.work_dir, paths.out_dir],
               cd: tmp_dir,
               env: env,
               timeout_ms: 120_000
             )

    project_yaml = File.read!(Path.join(paths.capture, "project.yaml"))
    assert project_yaml =~ ~s(model: "benchmark-shaper")
    assert project_yaml =~ ~s(effort: "benchmark-effort")
  end

  @tag intent: "shaper-uses-sol/A4"
  test "intent shape help documents the default", %{tmp_dir: tmp_dir} do
    help = cli(["intent", "shape", "--help"], tmp_dir)

    assert help =~ "gpt-6.1-sol"
    assert help =~ "high effort"
  end

  @tag intent: "shaper-uses-sol/A5"
  test "README documents the default" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))

    assert readme =~ "gpt-6.1-sol"
    assert readme =~ "high effort"
  end

  defp benchmark_fixture(tmp_dir) do
    paths = %{
      task_dir: Path.join(tmp_dir, @bench_slug),
      work_dir: Git.create!(Path.join(tmp_dir, "work")),
      out_dir: Path.join(tmp_dir, "out"),
      fake_kogen: Path.join(tmp_dir, "fake-kogen"),
      capture: Path.join(tmp_dir, "capture")
    }

    File.mkdir_p!(paths.task_dir)
    File.mkdir_p!(paths.capture)
    File.mkdir_p!(Path.join(tmp_dir, "home"))
    File.write!(Path.join(paths.task_dir, "prompt.md"), "Shape this benchmark task.\n")
    File.write!(Path.join(paths.task_dir, "task.json"), ~s({"env": {}}\n))
    File.write!(paths.fake_kogen, fake_kogen_script())
    File.chmod!(paths.fake_kogen, 0o755)
    paths
  end

  defp fake_kogen_script do
    """
    #!/bin/sh
    set -eu
    command=$1
    shift
    case "$command" in
    #{fake_version_clause()}
    #{fake_intent_clause()}
    #{fake_queue_clause()}
    #{fake_status_clause()}
      *) exit 2 ;;
    esac
    """
  end

  defp fake_version_clause, do: "  version) echo 'kogen test' ;;"

  defp fake_intent_clause do
    """
      intent)
        action=$1
        shift
        case "$action" in
    #{fake_shape_clause()}
          approve) ;;
          *) exit 90 ;;
        esac
        ;;
    """
  end

  defp fake_shape_clause do
    """
          shape)
            slug=$1
            shift
            prompt=$1
            shift
            project=
            while [ "$#" -gt 0 ]; do
              if [ "$1" = --project ]; then project=$2; shift 2; else shift; fi
            done
            cp "$project/.kogen/project.yaml" "$KOGEN_BENCH_CAPTURE/project.yaml"
            mkdir -p "$project/.kogen/intents/$slug" "$project/.kogen/acceptance"
            cat > "$project/.kogen/intents/$slug/intent.md" <<'INTENT'
    ---
    title: Benchmark probe
    domains: [kernel]
    size: small
    ---
    Probe benchmark shaping.
    INTENT
            cat > "$project/.kogen/acceptance/${slug}_test.exs" <<'TEST'
    defmodule BenchmarkShapeProbeTest do
      use ExUnit.Case, async: true
      @tag intent: "shaper-bench-settings/A1"
      test "probe", do: assert(:ok == :ok)
    end
    TEST
            printf '%s\\n' '{"slug":"shaper-bench-settings","usage":[]}'
            ;;
    """
  end

  defp fake_queue_clause, do: "  queue) exit 1 ;;"

  defp fake_status_clause do
    """
      status)
        printf '%s\\n' '{"status":"failed","attempts":[],"candidate_diffs":[],"escalations":[],"model_stages":[],"phase_timings":[]}'
        ;;
    """
  end

  defp cli(args, cd) do
    TestProc.cmd!("elixir", child_args() ++ ["-e", "Kogen.Kernel.CLI.main(#{inspect(args)})"],
      cd: cd
    )
  end

  defp child_args do
    Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
  end
end
