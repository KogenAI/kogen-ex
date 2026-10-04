defmodule Kogen.Harness.Gate do
  @moduledoc false

  alias Kogen.Checks.Feedback
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.ProcResult
  alias Kogen.Harness.Gate.CommandRunner
  alias Kogen.Harness.GateCommand
  alias Kogen.Harness.GateResult
  alias Kogen.Harness.Opts

  @max_excused_tests 2
  @module_reference ~r/\b[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\b/
  @environment_paths ["mix.exs", "mix.lock", ".mise.toml", ".kogen/project.yaml"]

  @spec run(Opts.t(), integer()) :: {:ok, GateResult.t()} | {:error, term()}
  def run(%Opts{} = opts, deadline) do
    with :ok <- before_gate(opts.before_gate),
         {:ok, fixes, _fix_flakes} <- run_specs(opts, opts.project.fix, deadline, :fix),
         {:ok, checks, flake_excused} <- run_specs(opts, opts.project.checks, deadline, :check) do
      commands = fixes ++ checks
      exit_level = Feedback.overall_exit_level(commands)

      status =
        case exit_level do
          0 -> :pass
          3 -> :environment
          _level -> :fail
        end

      failures =
        case status do
          :pass -> []
          :environment -> [Feedback.render_environment_detail(commands)]
          :fail -> [Feedback.render_model_feedback(commands)]
        end

      {:ok,
       %GateResult{
         status: status,
         fixes: fixes,
         checks: checks,
         failures: failures,
         flake_excused: flake_excused,
         failed_test_count: failed_test_count(checks, opts.project.checks)
       }}
    end
  end

  defp before_gate(nil), do: :ok
  defp before_gate(guard) when is_function(guard, 0), do: guard.()

  defp failed_test_count(commands, specs) do
    test_names = specs |> Enum.filter(&mix_test?(&1.argv)) |> MapSet.new(& &1.name)
    test_commands = Enum.filter(commands, &MapSet.member?(test_names, &1.name))

    if test_commands != [] and Enum.all?(test_commands, &test_count_known?/1) do
      test_commands
      |> Enum.flat_map(fn
        %{exit_level: 1, findings: findings} -> findings
        _passed -> []
      end)
      |> Enum.filter(&(&1.tool == "exunit" and is_binary(&1.symbol)))
      |> Enum.map(& &1.symbol)
      |> Enum.uniq()
      |> length()
    end
  end

  defp test_count_known?(%{tool: "exunit", exit_level: 0}), do: true

  defp test_count_known?(%{tool: "exunit", exit_level: 1, findings: findings}),
    do: Enum.any?(findings, &(&1.tool == "exunit" and is_binary(&1.symbol)))

  defp test_count_known?(_command), do: false

  defp run_specs(opts, specs, deadline, kind) do
    specs
    |> Enum.reduce_while({:ok, [], []}, fn %CheckSpec{} = spec, {:ok, results, flakes} ->
      current_flakes =
        Enum.uniq(opts.flake_excused_test_ids ++ Enum.flat_map(flakes, & &1.test_ids))

      {result, excused} =
        run_spec(%{opts | flake_excused_test_ids: current_flakes}, spec, deadline, kind)

      result = assess_result(result, spec, opts.workdir)

      {:cont, {:ok, [result | results], excused ++ flakes}}
    end)
    |> case do
      {:ok, results, flakes} -> {:ok, Enum.reverse(results), Enum.reverse(flakes)}
      error -> error
    end
  end

  defp run_spec(opts, %CheckSpec{} = spec, deadline, :check) do
    if mix_test?(spec.argv) do
      {argv, seed} = seeded_argv(spec.argv)
      command = run_command(opts, spec, argv, deadline, :check, "")

      case {seed, Feedback.failed_test_ids(command.output, opts.workdir), command} do
        {seed, test_ids, %GateCommand{exit_status: status, timed_out: false}}
        when is_integer(seed) and status != 0 and test_ids != [] ->
          classify_test_failure(opts, spec, %{
            command: command,
            argv: spec.argv,
            deadline: deadline,
            seed: seed,
            test_ids: test_ids
          })

        _other ->
          {command, []}
      end
    else
      {run_command(opts, spec, spec.argv, deadline, :check, ""), []}
    end
  end

  defp run_spec(opts, %CheckSpec{} = spec, deadline, kind),
    do: {run_command(opts, spec, spec.argv, deadline, kind, ""), []}

  defp classify_test_failure(opts, spec, classification) do
    %{command: original, argv: argv, deadline: deadline, seed: seed, test_ids: test_ids} =
      classification

    retry_argv = retry_argv(argv, test_ids, seed)
    retry = run_command(opts, spec, retry_argv, deadline, :check, "-retry")

    if command_passed?(retry) do
      classify_on_base(
        opts,
        spec,
        Map.merge(classification, %{retry: retry, retry_argv: retry_argv})
      )
    else
      detail =
        "\nSame-seed rerun still failed: #{inspect(test_ids)} (seed #{seed}).\n#{retry.output}"

      {%{original | output: original.output <> detail}, []}
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
        test_id in base_failed_ids or not candidate_reaches_test?(opts, test_id, changed_paths)
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

  defp candidate_reaches_test?(_opts, _test_id, :unknown), do: true

  defp candidate_reaches_test?(opts, test_id, changed_paths) do
    case test_path(test_id, opts.workdir) do
      {:ok, test_path} ->
        case File.read(Path.join(opts.workdir, test_path)) do
          {:ok, source} ->
            module_paths = referenced_module_paths(source)

            Enum.any?(changed_paths, fn path ->
              path == test_path or
                path in module_paths or
                environment_path?(path) or
                test_support_path?(path)
            end)

          {:error, _reason} ->
            true
        end

      :error ->
        true
    end
  end

  # Reach is a direct-source heuristic: a changed test file, test support/config file, or
  # `lib/<Macro.underscore(Module.Name)>.ex` named in the test source counts as touched.
  # If the test source or changed-path list cannot be read, the result fails closed as reached.
  defp referenced_module_paths(source) do
    @module_reference
    |> Regex.scan(source)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.map(&Macro.underscore/1)
    |> Enum.map(&"lib/#{&1}.ex")
  end

  defp environment_path?(path),
    do: path in @environment_paths or String.starts_with?(path, "config/")

  defp test_support_path?(path), do: String.starts_with?(path, "test/")

  defp test_path(test_id, workdir) do
    case String.split(test_id, ":", parts: 2) do
      [path, _line] ->
        expanded = Path.expand(path, workdir)
        relative = Path.relative_to(expanded, Path.expand(workdir))

        if ".." in Path.split(relative) or Path.type(relative) == :absolute,
          do: :error,
          else: {:ok, relative}

      _other ->
        :error
    end
  end

  defp fit_excusal_cap(eligible, previously_excused) do
    previous = MapSet.new(previously_excused)
    repeat = Enum.filter(eligible, &MapSet.member?(previous, &1))
    new = Enum.reject(eligible, &MapSet.member?(previous, &1))
    available = max(@max_excused_tests - MapSet.size(previous), 0)
    repeat ++ Enum.take(new, available)
  end

  defp mix_test?([executable, "test" | _args]), do: Path.basename(executable) == "mix"
  defp mix_test?(_argv), do: false

  defp seeded_argv(argv) do
    case seed_in_args(Enum.drop(argv, 2)) do
      {:ok, seed} ->
        {argv, seed}

      :missing ->
        seed = System.unique_integer([:positive, :monotonic])
        {argv ++ ["--seed", Integer.to_string(seed)], seed}

      :invalid ->
        {argv, nil}
    end
  end

  defp seed_in_args(["--seed", value | _rest]), do: parse_seed(value)
  defp seed_in_args(["--seed=" <> value | _rest]), do: parse_seed(value)
  defp seed_in_args([_arg | rest]), do: seed_in_args(rest)
  defp seed_in_args([]), do: :missing

  defp parse_seed(value) do
    case Integer.parse(value) do
      {seed, ""} when seed >= 0 -> {:ok, seed}
      _other -> :invalid
    end
  end

  defp retry_argv(argv, test_ids, seed) do
    [executable, "test" | args] = argv

    options =
      args
      |> drop_seed_option()
      |> Enum.reject(&test_selector?/1)

    [executable, "test" | test_ids ++ options ++ ["--seed", Integer.to_string(seed)]]
  end

  defp drop_seed_option(["--seed", _value | rest]), do: drop_seed_option(rest)
  defp drop_seed_option(["--seed=" <> _value | rest]), do: drop_seed_option(rest)
  defp drop_seed_option([arg | rest]), do: [arg | drop_seed_option(rest)]
  defp drop_seed_option([]), do: []

  defp test_selector?(arg),
    do: String.ends_with?(arg, ".exs") or Regex.match?(~r/\.exs:\d+\z/, arg)

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
      Feedback.analyze(%{
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
