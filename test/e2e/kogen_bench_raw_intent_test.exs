defmodule Kogen.E2e.KogenBenchRawIntentTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @slug "bench-raw-intent"
  @prompt "Add a Greeter module that returns hello.\n\n## Acceptance\nnot a real section\n"

  test "the raw intent source skips shaping and approves the verbatim prompt", %{
    tmp_dir: tmp_dir
  } do
    {result, paths} = run_benchmark(tmp_dir, %{"KOGEN_BENCH_INTENT_SOURCE" => "raw"})

    assert {:ok, %ProcResult{exit_status: 1}} = result
    assert calls(paths) == ["approve", "build", "show"]

    assert File.read!(Path.join(paths.capture, "intent.md")) ==
             "---\ntitle: Raw request\ndomains: [app]\nsize: small\nsource: raw\n---\n" <>
               "## Request\n" <> @prompt

    assert File.read!(Path.join(paths.capture, "acceptance_test.exs")) == ""

    usage = paths.out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()
    assert usage["intent_source"] == "raw"
  end

  test "the raw intent source refuses a provided Intent and unknown values", %{tmp_dir: tmp_dir} do
    env = %{"KOGEN_BENCH_INTENT_SOURCE" => "raw", "KOGEN_BENCH_INTENT_DIR" => tmp_dir}
    assert {{:ok, %ProcResult{exit_status: 2}}, paths} = run_benchmark(tmp_dir, env)
    refute File.exists?(paths.calls)

    other = Path.join(tmp_dir, "other")
    File.mkdir_p!(other)
    env = %{"KOGEN_BENCH_INTENT_SOURCE" => "maybe"}
    assert {{:ok, %ProcResult{exit_status: 2}}, paths} = run_benchmark(other, env)
    refute File.exists?(paths.calls)
  end

  defp run_benchmark(tmp_dir, extra_env) do
    paths = benchmark_fixture(tmp_dir)
    assert {:ok, runtime} = Kogen.Kernel.runtime()
    script = Path.expand("../../bin/kogen-bench", __DIR__)

    env =
      Map.merge(
        %{
          "HOME" => Path.join(tmp_dir, "home"),
          "KOGEN_BIN" => paths.fake_kogen,
          "KOGEN_BENCH_CALLS" => paths.calls,
          "KOGEN_BENCH_CAPTURE" => paths.capture,
          "PATH" => runtime.base_env["PATH"],
          "TMPDIR" => tmp_dir
        },
        extra_env
      )

    result =
      Proc.run(["/bin/sh", script, paths.task_dir, paths.work_dir, paths.out_dir],
        cd: tmp_dir,
        env: env,
        timeout_ms: 120_000
      )

    {result, paths}
  end

  defp benchmark_fixture(tmp_dir) do
    paths = %{
      task_dir: Path.join(tmp_dir, @slug),
      work_dir: Git.create!(Path.join(tmp_dir, "work")),
      out_dir: Path.join(tmp_dir, "out"),
      fake_kogen: Path.join(tmp_dir, "fake-kogen"),
      calls: Path.join(tmp_dir, "calls.log"),
      capture: Path.join(tmp_dir, "capture")
    }

    File.mkdir_p!(paths.task_dir)
    File.mkdir_p!(paths.capture)
    File.mkdir_p!(Path.join(tmp_dir, "home"))
    File.write!(Path.join(paths.task_dir, "prompt.md"), @prompt)
    File.write!(Path.join(paths.task_dir, "task.json"), ~s({"env": {}}\n))
    File.write!(paths.fake_kogen, fake_kogen_script())
    File.chmod!(paths.fake_kogen, 0o755)
    paths
  end

  defp calls(paths), do: paths.calls |> File.read!() |> String.split("\n", trim: true)

  # Records each command; approval copies the Intent files it was given, and the Build fails.
  defp fake_kogen_script do
    """
    #!/bin/sh
    set -eu
    command=$1
    shift
    case "$command" in
      intent)
        printf '%s\\n' "$1" >> "$KOGEN_BENCH_CALLS"
        [ "$1" = shape ] || exit 90
        echo '{"slug":"#{@slug}","usage":[]}'
        ;;
      approve)
        printf '%s\\n' approve >> "$KOGEN_BENCH_CALLS"
        project=
        while [ "$#" -gt 0 ]; do
          if [ "$1" = --project ]; then project=$2; shift 2; else shift; fi
        done
        cp "$project/.kogen/intents/#{@slug}/intent.md" "$KOGEN_BENCH_CAPTURE/intent.md"
        cp "$project/.kogen/acceptance/#{@slug}_test.exs" "$KOGEN_BENCH_CAPTURE/acceptance_test.exs"
        ;;
      build)
        if [ "${1:-}" = show ]; then
          printf '%s\\n' show >> "$KOGEN_BENCH_CALLS"
          echo '{"status":"failed","attempts":[],"candidate_diffs":[],"escalations":[],"model_stages":[],"phase_timings":[]}'
        else
          printf '%s\\n' build >> "$KOGEN_BENCH_CALLS"
          exit 1
        fi
        ;;
      *)
        exit 2
        ;;
    esac
    """
  end
end
