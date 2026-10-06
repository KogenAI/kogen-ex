defmodule Kogen.Harness.Gate do
  @moduledoc false

  alias Kogen.Checks.Feedback
  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.CheckOutput
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Harness.Gate.Arguments
  alias Kogen.Harness.Gate.CommandRunner
  alias Kogen.Harness.Gate.TestCount
  alias Kogen.Harness.GateCommand
  alias Kogen.Harness.GateResult
  alias Kogen.Harness.Opts

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
            classify_failure(opts, spec, command, {argv, deadline, seed, test_ids})
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

  defp classify_failure(opts, spec, command, {argv, deadline, seed, test_ids}) do
    classification = %{
      command: command,
      argv: argv,
      retry_argv: Arguments.retry_argv(argv, test_ids, seed),
      deadline: deadline,
      seed: seed,
      test_ids: test_ids
    }

    Kogen.Flakes.classify(opts, spec, classification, fn retry_argv, retry_deadline, suffix ->
      run_command(opts, spec, retry_argv, retry_deadline, :check, suffix)
    end)
  end

  defp base_red_command?(opts, spec, command) do
    command
    |> assess_result(spec, opts.workdir)
    |> CheckBaseline.annotate(opts.check_baseline)
    |> Map.get(:base_red?, false)
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
end
