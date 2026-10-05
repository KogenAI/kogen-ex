defmodule Kogen.Acceptance.BenchShapeFallbackTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Testkit.Git

  @moduletag :acceptance
  @slug "bench-shape-fallback"
  @prompt "Add a Greeter module that returns hello.\n\n## Acceptance\nnot a real section\n"

  test "a provider error in shaping falls back to a raw-request Intent by default", %{
    tmp_dir: tmp_dir
  } do
    {result, paths} = run_benchmark(tmp_dir, 4, %{})

    assert {:ok, %ProcResult{exit_status: 1}} = result
    assert calls(paths) == ["shape", "approve", "build", "show"]

    intent_bytes = File.read!(Path.join(paths.capture, "intent.md"))
    assert intent_bytes =~ "## Request\n" <> @prompt
    assert {:ok, intent} = Kogen.Intent.parse_binary(intent_bytes, "intent.md")
    assert Kogen.Intent.lint(%{intent | slug: @slug}) == []
    assert Enum.map(intent.acceptance, &{&1.id, &1.verify}) == [{"A1", :test_keep}]

    smoke = File.read!(Path.join(paths.capture, "acceptance_test.exs"))
    assert smoke =~ ~s(@tag intent: "#{@slug}/A1")
    assert smoke =~ "Mix.Project.config()"

    usage = paths.out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()
    assert usage["intent_source"] == "raw-fallback"
  end

  test "the fallback can be turned off and shaping then fails with its exit status", %{
    tmp_dir: tmp_dir
  } do
    {result, paths} = run_benchmark(tmp_dir, 4, %{"KOGEN_BENCH_SHAPE_FALLBACK" => "none"})

    assert {:ok, %ProcResult{exit_status: 4}} = result
    assert calls(paths) == ["shape"]

    usage = paths.out_dir |> Path.join("usage.json") |> File.read!() |> :json.decode()
    assert usage["intent_source"] == "shaped"
    assert usage["failed_stage"] == "shape"
  end

  test "only provider errors fall back; other shaping failures still stop the run", %{
    tmp_dir: tmp_dir
  } do
    {result, paths} = run_benchmark(tmp_dir, 1, %{})

    assert {:ok, %ProcResult{exit_status: 1}} = result
    assert calls(paths) == ["shape"]
  end

  test "an unknown fallback mode is rejected before anything runs", %{tmp_dir: tmp_dir} do
    {result, paths} = run_benchmark(tmp_dir, 4, %{"KOGEN_BENCH_SHAPE_FALLBACK" => "maybe"})

    assert {:ok, %ProcResult{exit_status: 2}} = result
    refute File.exists?(paths.calls)
  end

  defp run_benchmark(tmp_dir, shape_status, extra_env) do
    paths = benchmark_fixture(tmp_dir, shape_status)
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

  defp benchmark_fixture(tmp_dir, shape_status) do
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
    File.write!(paths.fake_kogen, fake_kogen_script(shape_status))
    File.chmod!(paths.fake_kogen, 0o755)
    paths
  end

  defp calls(paths) do
    paths.calls |> File.read!() |> String.split("\n", trim: true)
  end

  defp fake_kogen_script(shape_status) do
    Enum.join(
      [
        "#!/bin/sh\nset -eu\ncommand=$1\nshift\ncase \"$command\" in\n",
        fake_shape_clause(shape_status),
        fake_approve_clause(),
        fake_build_clause(),
        "  *)\n    exit 2\n    ;;\nesac\n"
      ],
      "\n"
    )
  end

  defp fake_shape_clause(shape_status) do
    """
      intent)
        action=$1
        printf '%s\\n' "$action" >> "$KOGEN_BENCH_CALLS"
        [ "$action" = shape ] || exit 90
        echo "provider/timeout: ChatGPT request timed out." >&2
        exit #{shape_status}
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
        cp "$project/.kogen/intents/#{@slug}/intent.md" "$KOGEN_BENCH_CAPTURE/intent.md"
        cp "$project/.kogen/acceptance/#{@slug}_test.exs" "$KOGEN_BENCH_CAPTURE/acceptance_test.exs"
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
