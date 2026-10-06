defmodule Kogen.Acceptance.BenchProvidedIntentTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Testkit.Git

  @moduletag :acceptance
  @slug "bench-provided-intent"

  @tag intent: "bench-provided-intent/A1"
  test "uses provided files without shaping and records their source", %{tmp_dir: tmp_dir} do
    intent_dir = Path.join(tmp_dir, "provided")
    write_provided_files(intent_dir)

    {result, out_dir, calls_path} = run_benchmark(tmp_dir, intent_dir)

    assert {:ok, %ProcResult{exit_status: 1}} = result
    assert calls(calls_path) == ["approve", "build", "show"]

    usage = out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()
    assert usage["intent_source"] == "provided"
  end

  @tag intent: "bench-provided-intent/A2"
  test "shapes from the prompt when no provided directory is set", %{tmp_dir: tmp_dir} do
    {result, out_dir, calls_path} = run_benchmark(tmp_dir, nil)

    assert {:ok, %ProcResult{exit_status: 1}} = result
    assert calls(calls_path) == ["shape", "approve", "build", "show"]

    usage = out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()
    assert usage["intent_source"] == "shaped"

    assert [%{"model" => "fixture-shaper", "tokens" => %{"input" => 12}}] =
             Enum.find(usage["stages"], &(&1["stage"] == "shape"))["calls"]
  end

  defp run_benchmark(tmp_dir, intent_dir) do
    paths = benchmark_fixture(tmp_dir)
    assert {:ok, runtime} = Kogen.Kernel.runtime()
    env = benchmark_env(paths, tmp_dir, intent_dir, runtime)
    script = Path.expand("../../bin/kogen-bench", __DIR__)

    result =
      Proc.run(["/bin/sh", script, paths.task_dir, paths.work_dir, paths.out_dir],
        cd: tmp_dir,
        env: env,
        timeout_ms: 120_000
      )

    {result, paths.out_dir, paths.calls_path}
  end

  defp benchmark_fixture(tmp_dir) do
    paths = %{
      task_dir: Path.join(tmp_dir, @slug),
      work_dir: Git.create!(Path.join(tmp_dir, "work")),
      out_dir: Path.join(tmp_dir, "out"),
      fake_kogen: Path.join(tmp_dir, "fake-kogen"),
      calls_path: Path.join(tmp_dir, "calls.log")
    }

    File.mkdir_p!(paths.task_dir)
    File.mkdir_p!(Path.join(tmp_dir, "home"))
    File.write!(Path.join(paths.task_dir, "prompt.md"), "Implement the task from prompt.md.\n")

    File.write!(
      Path.join(paths.task_dir, "task.json"),
      IO.iodata_to_binary(:json.encode(%{"env" => %{}}))
    )

    File.write!(paths.fake_kogen, fake_kogen_script())
    File.chmod!(paths.fake_kogen, 0o755)
    paths
  end

  defp benchmark_env(paths, tmp_dir, intent_dir, runtime) do
    env = %{
      "HOME" => Path.join(tmp_dir, "home"),
      "KOGEN_BIN" => paths.fake_kogen,
      "KOGEN_BENCH_CALLS" => paths.calls_path,
      "PATH" => runtime.base_env["PATH"],
      "TMPDIR" => tmp_dir
    }

    if intent_dir do
      Map.merge(env, %{
        "KOGEN_BENCH_INTENT_DIR" => intent_dir,
        "KOGEN_EXPECT_INTENT_DIR" => intent_dir
      })
    else
      env
    end
  end

  defp write_provided_files(intent_dir) do
    File.mkdir_p!(intent_dir)

    File.write!(
      Path.join(intent_dir, "intent.md"),
      "---\ntitle: Provided benchmark intent\ndomains: [engine]\nsize: small\n---\nUse the supplied specification.\n"
    )

    File.write!(
      Path.join(intent_dir, "acceptance_test.exs"),
      """
      defmodule ProvidedBenchmarkIntentAcceptanceTest do
        use ExUnit.Case, async: true

        @tag intent: "bench-provided-intent/A1"
        test "the provided acceptance test is available" do
          assert :ok == :ok
        end
      end
      """
    )
  end

  defp calls(path) do
    path |> File.read!() |> String.split("\n", trim: true)
  end

  defp fake_kogen_script do
    Enum.join(
      [
        """
        #!/bin/sh
        set -eu
        command=$1
        shift
        case "$command" in
        """,
        fake_intent_clause(),
        fake_approve_clause(),
        fake_build_clause(),
        """
          *)
            exit 2
            ;;
        esac
        """
      ],
      "\n"
    )
  end

  defp fake_intent_clause do
    """
      intent)
        action=$1
        printf '%s\\n' "$action" >> "$KOGEN_BENCH_CALLS"
        [ "$action" = shape ] || exit 90
        for argument in "$@"; do
          [ "$argument" != --json ] || exit 2
        done
        transcript="$(dirname "$KOGEN_BENCH_CALLS")/shape-transcript.jsonl"
        printf '%s\\n' '{"event":"model_usage","stage":"shape","payload":{"model":"fixture-shaper","effort":"high","tokens":{"input":12},"wall_ms":7}}' > "$transcript"
        printf 'Intent: shaped\\nTranscript: %s\\n' "$transcript"
        ;;
    """
  end

  defp fake_approve_clause do
    """
      approve)
        printf '%s\\n' approve >> "$KOGEN_BENCH_CALLS"
        project=
        while [ "$#" -gt 0 ]; do
          if [ "$1" = --project ]; then
            project=$2
            shift 2
          else
            shift
          fi
        done
        if [ -n "${KOGEN_EXPECT_INTENT_DIR:-}" ]; then
          cmp "$KOGEN_EXPECT_INTENT_DIR/intent.md" \\
            "$project/.kogen/intents/bench-provided-intent/intent.md"
          cmp "$KOGEN_EXPECT_INTENT_DIR/acceptance_test.exs" \\
            "$project/.kogen/acceptance/bench-provided-intent_test.exs"
        fi
        ;;
    """
  end

  defp fake_build_clause do
    """
      build)
        if [ "${1:-}" = show ]; then
          printf '%s\\n' show >> "$KOGEN_BENCH_CALLS"
          printf '%s\\n' '{"status":"failed","attempts":[],"candidate_diffs":[],"escalations":[],"model_stages":[],"phase_timings":[]}'
        else
          printf '%s\\n' build >> "$KOGEN_BENCH_CALLS"
          exit 1
        fi
        ;;
    """
  end
end
