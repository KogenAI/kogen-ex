defmodule Kogen.Proc.ProcTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc

  test "returns a non-zero exit status and combines stdout with stderr", %{tmp_dir: tmp_dir} do
    assert {:ok, %ProcResult{exit_status: 7, timed_out: false, output_tail: output}} =
             run(["sh", "-c", "printf 'out'; printf 'err' >&2; exit 7"], tmp_dir)

    assert output == "outerr"
  end

  test "uses /dev/null when stdin is nil", %{tmp_dir: tmp_dir} do
    assert {:ok, %ProcResult{exit_status: 0, output_tail: ""}} =
             run(["cat"], tmp_dir, stdin: nil)
  end

  test "writes binary stdin through a private file", %{tmp_dir: tmp_dir} do
    data = <<"binary", 0, "stdin\n">>

    assert {:ok, %ProcResult{exit_status: 0, output_tail: ^data}} =
             run(["cat"], tmp_dir, stdin: {:binary, data})
  end

  test "reads stdin from an explicit file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "input.txt")
    File.write!(path, "from file\n")

    assert {:ok, %ProcResult{exit_status: 0, output_tail: "from file\n"}} =
             run(["cat"], tmp_dir, stdin: {:file, path})
  end

  test "kills a sleeping child at its wall deadline", %{tmp_dir: tmp_dir} do
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %ProcResult{exit_status: nil, timed_out: true}} =
             run(["sleep", "30"], tmp_dir, timeout_ms: 2_000)

    assert System.monotonic_time(:millisecond) - started_at < 15_000
  end

  test "escalates to KILL when the child ignores TERM", %{tmp_dir: tmp_dir} do
    timeout_ms = 2_000
    grace_ms = 200
    term_received = Path.join(tmp_dir, "term-received")
    started_at = System.monotonic_time(:millisecond)

    script = ~S"""
    use strict;
    use warnings;
    $SIG{TERM} = sub {
      open my $marker, ">", $ENV{KOGEN_TERM_RECEIVED} or die "record TERM: $!";
      print {$marker} "received";
      close $marker or die "close TERM marker: $!";
    };
    while (1) { select undef, undef, undef, 1; }
    """

    assert {:ok, %ProcResult{exit_status: nil, timed_out: true}} =
             run(["/usr/bin/perl", "-e", script], tmp_dir,
               env: %{"KOGEN_TERM_RECEIVED" => term_received},
               timeout_ms: timeout_ms
             )

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert File.read!(term_received) == "received"

    # This clock starts before wrapper startup; allow small scheduling and millisecond rounding
    # while requiring the timeout plus the full TERM grace period before Proc.run returns.
    assert elapsed >= timeout_ms + grace_ms - 20
    assert elapsed < 15_000
  end

  test "a continuously writing child cannot starve the deadline", %{tmp_dir: tmp_dir} do
    assert {:ok, %ProcResult{timed_out: true, exit_status: nil, output_tail: tail}} =
             run(["yes"], tmp_dir, timeout_ms: 2_000)

    assert byte_size(tail) <= 16 * 1024
  end

  test "kills a background grandchild with the process group", %{tmp_dir: tmp_dir} do
    ready = Path.join(tmp_dir, "grandchild-ready")
    marker = Path.join(tmp_dir, "grandchild-killed")

    script =
      "sh -c 'trap \"printf killed > $MARKER; exit 0\" TERM; sleep 30 & printf ready > $READY; wait' & " <>
        "while [ ! -f $READY ]; do sleep 0.01; done; exit 0"

    assert {:ok, %ProcResult{exit_status: 0}} =
             run(["sh", "-c", script], tmp_dir,
               env: %{"MARKER" => marker, "READY" => ready},
               timeout_ms: 10_000
             )

    assert wait_for_content(marker, "killed")
  end

  test "only explicit environment values reach the child", %{tmp_dir: tmp_dir} do
    assert {:ok, %ProcResult{output_tail: "unset|visible"}} =
             run(
               ["sh", "-c", ~s(printf '%s|%s' "${HOME-unset}" "$KOGEN_PASSED")],
               tmp_dir,
               env: %{"KOGEN_PASSED" => "visible"}
             )
  end

  test "removes explicit Kogen ERTS and escript roots from PATH", %{tmp_dir: tmp_dir} do
    erts_root = Path.join(tmp_dir, "kogen/erts-29.1.1")
    escript_root = Path.join(tmp_dir, "kogen/gen/current")
    erts_bin = Path.join(erts_root, "bin")
    escript_bin = Path.join(escript_root, "bin")
    path = Enum.join([erts_bin, escript_bin, "/usr/bin:/bin"], ":")

    assert {:ok, %ProcResult{output_tail: "/usr/bin:/bin|unset|unset"}} =
             run(
               ["sh", "-c", ~s(printf '%s|%s|%s' "$PATH" "${ROOTDIR-unset}" "${BINDIR-unset}")],
               tmp_dir,
               env: %{
                 "PATH" => path,
                 "ROOTDIR" => erts_root,
                 "BINDIR" => erts_bin,
                 "KOGEN_ESCRIPT_DIR" => escript_root
               }
             )
  end

  test "writes the full log and returns only its 16 KB tail", %{tmp_dir: tmp_dir} do
    log_path = Path.join(tmp_dir, "process.log")

    assert {:ok, %ProcResult{exit_status: 0, output_tail: tail}} =
             run(
               ["sh", "-c", "head -c 20000 /dev/zero | tr '\\000' A"],
               tmp_dir,
               log_path: log_path
             )

    full_log = File.read!(log_path)
    assert byte_size(full_log) == 20_000
    assert byte_size(tail) == 16 * 1024
    assert tail == binary_part(full_log, 20_000 - 16 * 1024, 16 * 1024)
  end

  test "returns enoent for an executable that does not exist", %{tmp_dir: tmp_dir} do
    assert {:error, :enoent} = run(["kogen-no-such-executable"], tmp_dir)
  end

  test "reaps the process group when the calling process dies", %{tmp_dir: tmp_dir} do
    caller = self()
    ready = Path.join(tmp_dir, "caller-ready")
    marker = Path.join(tmp_dir, "caller-killed")

    # `sleep` runs in the background and the shell blocks in `wait`, which TERM interrupts at once.
    # In the foreground, a TERM that lands between fork and exec of `sleep` is lost: the shell
    # waits for `sleep 30`, the wrapper escalates to KILL and the trap never runs.
    script =
      ~s(trap 'printf killed > "$MARKER"; exit 0' TERM; sleep 30 & printf ready > "$READY"; wait)

    run_pid =
      spawn(fn ->
        send(caller, :runner_started)

        run(["sh", "-c", script], tmp_dir,
          env: %{"MARKER" => marker, "READY" => ready},
          timeout_ms: 10_000
        )
      end)

    run_monitor = Process.monitor(run_pid)
    assert_receive :runner_started, 10_000
    assert wait_for_file(ready)
    Process.exit(run_pid, :kill)
    assert_receive {:DOWN, ^run_monitor, :process, ^run_pid, :killed}, 10_000
    assert wait_for_content(marker, "killed")
  end

  @tag :process
  test "reaps the process group when the BEAM dies", %{tmp_dir: tmp_dir} do
    elixir = System.find_executable("elixir")
    beam_dir = Path.dirname(:code.which(Proc))
    beam_pid_path = Path.join(tmp_dir, "nested-beam-pid")
    ready = Path.join(tmp_dir, "beam-child-ready")
    marker = Path.join(tmp_dir, "beam-child-killed")
    child_ready = Path.join(tmp_dir, "beam-child-running")

    source = beam_death_source(tmp_dir, beam_pid_path, ready, marker, child_ready)
    source_path = Path.join(tmp_dir, "nested_beam.exs")
    File.write!(source_path, source)

    nested_env = %{
      "PATH" =>
        Enum.join(
          [Path.dirname(elixir), Path.join(:code.root_dir(), "bin"), "/usr/bin", "/bin"],
          ":"
        )
    }

    test_owner = self()

    run_pid =
      spawn(fn ->
        result = run([elixir, "-pa", beam_dir, source_path], tmp_dir, env: nested_env)
        send(test_owner, {:nested_done, result})
      end)

    run_monitor = Process.monitor(run_pid)

    assert wait_for_file(child_ready)
    beam_pid = File.read!(beam_pid_path)
    assert {:ok, %ProcResult{exit_status: 0}} = run(["kill", "-9", beam_pid], tmp_dir)
    assert wait_for_content(marker, "killed")
    assert_receive {:nested_done, {:ok, %ProcResult{exit_status: 137}}}, 5_000
    assert_receive {:DOWN, ^run_monitor, :process, ^run_pid, :normal}, 5_000
  end

  defp beam_death_source(tmp_dir, beam_pid_path, ready, marker, child_ready) do
    """
    File.write!(#{inspect(beam_pid_path)}, System.pid())
    File.write!(#{inspect(ready)}, "ready")
    Kogen.Proc.run(
      ["sh", "-c", "trap 'printf killed > \\\"$MARKER\\\"; exit 0' TERM; sleep 30 & printf ready > \\\"$READY\\\"; wait"],
      cd: #{inspect(tmp_dir)},
      env: %{"PATH" => "/usr/bin:/bin", "MARKER" => #{inspect(marker)}, "READY" => #{inspect(child_ready)}},
      timeout_ms: 10_000
    )
    """
  end

  defp run(argv, cd, opts \\ []) do
    Proc.run(argv, Keyword.merge([cd: cd], opts))
  end

  # Existence is not enough: the trap's redirect creates the file before printf writes to it.
  defp wait_for_content(path, expected, attempts \\ 500)
  defp wait_for_content(path, expected, 0), do: File.read(path) == {:ok, expected}

  defp wait_for_content(path, expected, attempts) do
    if File.read(path) == {:ok, expected} do
      true
    else
      receive do
      after
        10 -> wait_for_content(path, expected, attempts - 1)
      end
    end
  end

  defp wait_for_file(path, attempts \\ 500)
  defp wait_for_file(path, 0), do: File.exists?(path)

  defp wait_for_file(path, attempts) do
    if File.exists?(path) do
      true
    else
      receive do
      after
        10 -> wait_for_file(path, attempts - 1)
      end
    end
  end
end
