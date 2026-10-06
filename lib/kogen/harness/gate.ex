defmodule Kogen.Harness.Gate do
  @moduledoc false

  alias Kogen.Checks.Feedback
  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.CheckOutput
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.ProcResult
  alias Kogen.Harness.Gate.Arguments
  alias Kogen.Harness.Gate.CommandRunner
  alias Kogen.Harness.Gate.TestCount
  alias Kogen.Harness.GateCommand
  alias Kogen.Harness.GateResult
  alias Kogen.Harness.Opts

  @max_excused_tests 2

  @spec run(Opts.t(), integer()) :: {:ok, GateResult.t()} | {:error, term()}
  def run(%Opts{} = opts, deadline) do
    with :ok <- before_gate(opts.before_gate),
         {:ok, fixes, _fix_flakes} <- run_specs(opts, opts.project.fix, deadline, :fix),
         {:ok, checks, flake_excused} <- run_specs(opts, opts.project.checks, deadline, :check) do
      checks = checks ++ quality_commands(opts, deadline)
      commands = Enum.reject(fixes ++ checks, & &1.base_red?)
      status = if Feedback.overall_exit_level(commands) == 0, do: :pass, else: :fail

      failures =
        if status == :pass,
          do: [],
          else: [Feedback.render_model_feedback(commands, opts.changed_ranges)]

      warnings =
        Enum.flat_map(fixes ++ checks, &CheckBaseline.warning/1) ++
          Enum.flat_map(checks, &Map.get(&1, :warnings, []))

      {:ok,
       %GateResult{
         status: status,
         fixes: fixes,
         checks: checks,
         failures: failures,
         warnings: warnings,
         flake_excused: flake_excused,
         failed_test_count: TestCount.failed_test_count(checks, opts.project.checks)
       }}
    end
  end

  defp quality_commands(opts, deadline) do
    opts.workdir
    |> Kogen.Quality.Request.new(opts.run_dir, opts.env, %{
      base: opts.base,
      sandbox: opts.sandbox,
      deadline: deadline
    })
    |> Kogen.Quality.commands()
    |> Enum.map(&CheckBaseline.annotate(&1, opts.check_baseline))
  end

  defp before_gate(nil), do: :ok
  defp before_gate(guard) when is_function(guard, 0), do: guard.()

  defp run_specs(opts, specs, deadline, kind) do
    specs
    |> Enum.reduce_while({:ok, [], []}, fn %CheckSpec{} = spec, {:ok, results, flakes} ->
      current_flakes =
        Enum.uniq(opts.flake_excused_test_ids ++ Enum.flat_map(flakes, & &1.test_ids))

      spec = if kind == :fix, do: %{spec | name: "fix/#{spec.name}"}, else: spec

      run = fn ->
        {command, excused} =
          run_spec(%{opts | flake_excused_test_ids: current_flakes}, spec, deadline, kind)

        {assess_result(command, spec, opts.workdir), excused}
      end

      case Kogen.Checks.verify_command(opts.workdir, opts.env, spec, opts.check_baseline, run) do
        {:ok, {result, excused}} ->
          {:cont, {:ok, [result | results], excused ++ flakes}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results, flakes} -> {:ok, Enum.reverse(results), Enum.reverse(flakes)}
      error -> error
    end
  end

  defp run_spec(opts, %CheckSpec{} = spec, deadline, :check) do
    if mix_test?(spec.argv) do
      {argv, seed} = Arguments.seeded_argv(spec.argv)
      command = run_command(opts, spec, argv, deadline, :check, "")

      case {seed, Feedback.failed_test_ids(command.output, opts.workdir), command} do
        {seed, test_ids, %GateCommand{exit_status: status, timed_out: false}}
        when is_integer(seed) and status != 0 and test_ids != [] ->
          if base_red_command?(opts, spec, command) do
            {command, []}
          else
            classify_test_failure(opts, spec, %{
              command: command,
              argv: spec.argv,
              deadline: deadline,
              seed: seed,
              test_ids: test_ids
            })
          end

        _other ->
          {command, []}
      end
    else
      {run_command(opts, spec, spec.argv, deadline, :check, ""), []}
    end
  end

  defp run_spec(opts, %CheckSpec{} = spec, deadline, kind),
    do: {run_command(opts, spec, spec.argv, deadline, kind, ""), []}

  defp base_red_command?(opts, spec, command) do
    command
    |> assess_result(spec, opts.workdir)
    |> CheckBaseline.annotate(opts.check_baseline)
    |> Map.get(:base_red?, false)
  end

  defp classify_test_failure(opts, spec, classification) do
    %{command: original, argv: argv, deadline: deadline, seed: seed, test_ids: test_ids} =
      classification

    retry_argv = Arguments.retry_argv(argv, test_ids, seed)
    retry = run_command(opts, spec, retry_argv, deadline, :check, "-retry")

    if command_passed?(retry) do
      classify_on_base(
        opts,
        spec,
        Map.merge(classification, %{retry: retry, retry_argv: retry_argv})
      )
    else
      retry_ids = Feedback.failed_test_ids(retry.output, opts.workdir)

      if same_test_ids?(test_ids, retry_ids) and
           base_red?(opts, retry_argv, deadline, spec.timeout_ms, test_ids) do
        detail =
          "Environment failure (base-red): the same ExUnit failures reproduced on the clean " <>
            "base under the configured sandbox; skipped Developer repair for " <>
            "#{inspect(test_ids)}."

        {%{original | base_red?: true, output: original.output <> "\n" <> detail}, []}
      else
        detail =
          "\nSame-seed rerun still failed: #{inspect(test_ids)} (seed #{seed}).\n#{retry.output}"

        {%{original | output: original.output <> detail}, []}
      end
    end
  end

  defp same_test_ids?(left, right) do
    left != [] and MapSet.new(left) == MapSet.new(right)
  end

  defp base_red?(opts, argv, deadline, timeout_ms, test_ids) do
    case run_base_test(opts, argv, deadline, timeout_ms) do
      {:ok, %ProcResult{exit_status: status, timed_out: false, output_tail: output}}
      when is_integer(status) and status != 0 ->
        base_failed_ids = Feedback.failed_test_ids(output, opts.workdir)
        same_test_ids?(test_ids, base_failed_ids)

      _other ->
        false
    end
  end

  defp classify_on_base(opts, spec, classification) do
    %{
      command: original,
      deadline: deadline,
      seed: seed,
      test_ids: test_ids,
      retry: retry,
      retry_argv: retry_argv
    } = classification

    base_result = run_base_test(opts, retry_argv, deadline, spec.timeout_ms)
    base_failed_ids = base_failure_ids(base_result, opts.workdir)
    changed_paths = changed_paths(opts)

    eligible =
      Enum.filter(test_ids, fn test_id ->
        test_id in base_failed_ids or
          not Kogen.Quality.TestReach.reached?(opts, test_id, changed_paths)
      end)

    excused = fit_excusal_cap(eligible, opts.flake_excused_test_ids)
    real_failures = test_ids -- excused
    event = if excused == [], do: [], else: [%{test_ids: excused, seed: seed}]

    if real_failures == [] do
      detail =
        "\nSame-seed rerun passed for #{inspect(test_ids)}; base/unreached tests excused " <>
          "with seed #{seed}.\n#{retry.output}"

      {%{original | exit_status: 0, timed_out: false, output: original.output <> detail}, event}
    else
      detail =
        "\nSame-seed rerun passed, but these tests remain Candidate failures: " <>
          "#{inspect(real_failures)} (seed #{seed}).\n#{retry.output}"

      {%{original | output: original.output <> detail}, event}
    end
  end

  defp run_base_test(%Opts{base_test: base_test}, argv, deadline, timeout_ms)
       when is_function(base_test, 2) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      {:error, :deadline_reached}
    else
      base_test.(argv, min(timeout_ms, remaining_ms))
    end
  end

  defp run_base_test(_opts, _argv, _deadline, _timeout_ms), do: {:error, :base_test_unavailable}

  defp base_failure_ids(
         {:ok, %ProcResult{output_tail: output, exit_status: status, timed_out: timed_out}},
         workdir
       )
       when timed_out or status != 0, do: Feedback.failed_test_ids(output, workdir)

  defp base_failure_ids(_result, _workdir), do: []

  defp changed_paths(%Opts{changed_paths: changed_paths}) when is_function(changed_paths, 0) do
    case changed_paths.() do
      {:ok, paths} when is_list(paths) -> paths
      _error -> :unknown
    end
  end

  defp changed_paths(_opts), do: :unknown

  defp fit_excusal_cap(eligible, previously_excused) do
    previous = MapSet.new(previously_excused)
    repeat = Enum.filter(eligible, &MapSet.member?(previous, &1))
    new = Enum.reject(eligible, &MapSet.member?(previous, &1))
    available = max(@max_excused_tests - MapSet.size(previous), 0)
    repeat ++ Enum.take(new, available)
  end

  defp mix_test?([executable, "test" | _args]), do: Path.basename(executable) == "mix"
  defp mix_test?(_argv), do: false

  defp run_command(opts, spec, argv, deadline, kind, suffix) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      %GateCommand{
        name: spec.name,
        exit_status: nil,
        timed_out: true,
        output: "Harness wall deadline reached before this command ran."
      }
    else
      run_argv(opts, spec, argv, min(spec.timeout_ms, remaining_ms), kind, suffix)
    end
  end

  defp assess_result(%GateCommand{} = command, %CheckSpec{} = spec, workdir) do
    assessment =
      Feedback.analyze(%CheckOutput{
        name: spec.name,
        argv: spec.argv,
        exit_status: command.exit_status,
        timed_out: command.timed_out,
        output: command.output,
        log_path: command.log_path,
        workdir: workdir
      })

    %{
      command
      | tool: assessment.tool,
        exit_level: assessment.exit_level,
        findings: assessment.findings,
        dialyzer_summaries: assessment.dialyzer_summaries,
        reason: assessment.reason
    }
  end

  defp run_argv(opts, spec, argv, timeout_ms, kind, suffix) do
    CommandRunner.run(opts, spec, argv, timeout_ms, kind, suffix)
  end

  defp command_passed?(%GateCommand{exit_status: 0, timed_out: false}), do: true
  defp command_passed?(_command), do: false
end
