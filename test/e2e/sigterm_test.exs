defmodule Kogen.E2e.SigtermTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Environment
  alias Kogen.E2e.Build.Signal
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @tag timeout: 120_000

  setup_all do
    seed_project = Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)
    {:ok, seed_project: seed_project}
  end

  test "SIGTERM interrupts a scripted Build, reaps its shell, and leaves it reconcilable",
       context do
    parent = Path.join(context.tmp_dir, "sigterm-build")
    File.mkdir_p!(parent)

    project = Path.join(parent, "project")
    home = Path.join(parent, "test-home")
    origin = Path.join(parent, "origin.git")
    workspace_root = Signal.workspace_root(project, home)
    pid_path = Path.join(parent, "beam.pid")
    child_env = Environment.child_env!(home)
    elixir = Environment.executable!(child_env, "elixir")

    script =
      "Kogen.E2e.Build.run_blocked_cli!(#{inspect(parent)}, #{inspect(context.seed_project)}, #{inspect(pid_path)})"

    task =
      Task.async(fn ->
        case Signal.run_child([elixir | child_args() ++ ["-e", script]],
               cd: parent,
               env: child_env,
               timeout_ms: 120_000
             ) do
          {:ok, result} -> {result.exit_status, result.output_tail}
          {:error, reason} -> {:error, reason}
        end
      end)

    try do
      assert {:ok, marker} = wait_for_child_marker(workspace_root, task, 30_000)
      shell_pid = marker |> File.read!() |> String.trim()
      beam_pid = pid_path |> File.read!() |> String.trim()

      assert Signal.process_alive?(shell_pid)
      assert :ok = Signal.signal_process(beam_pid, "TERM")

      {exit_status, output} = Task.await(task, 30_000)
      assert exit_status == 143, output
      assert wait_until_dead(shell_pid, 3_000)

      assert {:ok, outcome} =
               Signal.reconcile_run(project, workspace_root, origin, home, Git.env())

      assert outcome.run_status == :running
      assert outcome.interrupted
      assert outcome.reconciliation == :crashed
      assert outcome.reconciled_status == :failed
      assert outcome.claim_released
    after
      terminate_task(task, pid_path)
      terminate_marker(workspace_root)
    end
  end

  defp wait_for_child_marker(workspace_root, task, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_child_marker_until(workspace_root, task, deadline)
  end

  defp wait_for_child_marker_until(workspace_root, task, deadline) do
    case Task.yield(task, 0) do
      {:ok, result} ->
        {:error, {:child_exited, result}}

      {:exit, reason} ->
        {:error, {:child_exit, reason}}

      nil ->
        marker = Path.wildcard(Path.join([workspace_root, "*", "lib", "kogen-term-child.pid"]))

        cond do
          marker != [] ->
            {:ok, hd(marker)}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, :timeout}

          true ->
            receive do
            after
              50 -> :ok
            end

            wait_for_child_marker_until(workspace_root, task, deadline)
        end
    end
  end

  defp wait_until_dead(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until_dead_until(pid, deadline)
  end

  defp wait_until_dead_until(pid, deadline) do
    cond do
      not Signal.process_alive?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          50 -> :ok
        end

        wait_until_dead_until(pid, deadline)
    end
  end

  defp terminate_task(task, pid_path) do
    if Task.yield(task, 0) == nil do
      if File.regular?(pid_path) do
        _ = Signal.signal_process(String.trim(File.read!(pid_path)), "TERM")
      end

      _ = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    end
  end

  defp terminate_marker(workspace_root) do
    workspace_root
    |> Path.join("*/lib/kogen-term-child.pid")
    |> Path.wildcard()
    |> Enum.each(fn marker ->
      pid = String.trim(File.read!(marker))
      if Signal.process_alive?(pid), do: Signal.signal_process(pid, "KILL")
    end)
  end

  defp child_args do
    Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
  end
end
