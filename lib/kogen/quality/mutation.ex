defmodule Kogen.Quality.Mutation do
  @moduledoc "Bounded advisory changed-line mutation qualification; never a score gate."
  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Quality.Mutation.Plan
  alias Kogen.Quality.Report
  alias Kogen.Quality.Snapshot

  @limit 6
  @spec run(struct(), [Path.t()]) :: map()
  def run(request, paths) do
    started = System.monotonic_time(:millisecond)
    result = with {:ok, plan} <- Plan.build(request, paths), do: qualify(request, paths, plan)

    report =
      case result do
        {:ok, report} -> report
        {:error, reason} -> %{complete: false, reason: inspect(reason), eligible: 0, trials: []}
      end

    report =
      Map.merge(report, %{
        wall_ms: System.monotonic_time(:millisecond) - started,
        limit: @limit,
        policy: "advisory; calibration pending",
        operator_scope:
          "binary comparisons, arithmetic and boolean operators on changed lib lines"
      })

    file = Path.join(request.run_dir, "mutation-qualification.json")

    case File.write(file, JSON.encode!(report)) do
      :ok -> command(report, file)
      {:error, reason} -> Report.skip("mutation", "report write failed: #{inspect(reason)}")
    end
  end

  defp qualify(_request, _paths, []), do: {:ok, %{complete: true, eligible: 0, trials: []}}

  defp qualify(request, paths, plan) do
    with {:ok, snapshot} <- Snapshot.create(%{request | mix_env: "test"}, paths) do
      try do
        tests =
          snapshot
          |> Path.join("test/**/*_test.exs")
          |> Path.wildcard()
          |> Enum.map(&Path.relative_to(&1, snapshot))
          |> Enum.sort()

        argv = ["mix", "test", "--seed", "0"] ++ tests

        baseline =
          if tests == [],
            do: %{status: "unavailable", reason: "no tests"},
            else: execute(request, snapshot, argv)

        trials =
          if baseline.status == "survived",
            do: trials(request, snapshot, argv, Enum.take(plan, @limit)),
            else: []

        {:ok,
         %{
           eligible: length(plan),
           complete:
             length(trials) == length(plan) and
               Enum.all?(trials, &(&1.status in ["killed", "survived"])),
           baseline: baseline,
           tests: tests,
           reproduction_argv: argv,
           trials: trials
         }}
      after
        File.rm_rf(snapshot)
      end
    end
  end

  defp trials(request, snapshot, argv, plan) do
    plan
    |> Enum.reduce_while([], fn item, acc ->
      if System.monotonic_time(:millisecond) >= request.deadline do
        {:halt, Enum.reverse(acc)}
      else
        path = Path.join(snapshot, item.path)
        original = File.read!(path)
        mutated = Plan.apply(original, item)

        result =
          try do
            File.write!(path, mutated)

            if original == mutated,
              do: %{status: "invalid", reason: "token position unavailable"},
              else: execute(request, snapshot, argv)
          after
            File.write!(path, original)
          end

        trial = item |> Map.merge(result) |> Map.put(:tests, Enum.drop(argv, 4))
        {:cont, [trial | acc]}
      end
    end)
    |> then(fn trials -> Enum.sort_by(trials, &{&1.path, &1.line, &1.column}) end)
  end

  defp execute(request, snapshot, argv) do
    remaining = max(request.deadline - System.monotonic_time(:millisecond), 1)
    log = Path.join(request.run_dir, "logs/mutation-#{System.unique_integer([:positive])}.log")
    sandbox = if request.sandbox, do: %{request.sandbox | workspace: snapshot}

    case Proc.run(argv,
           cd: snapshot,
           env: Kogen.Quality.Codec.test_env(request.env),
           timeout_ms: min(remaining, 5_000),
           log_path: log,
           sandbox: sandbox
         ) do
      {:ok, %ProcResult{} = result} ->
        status = trial_status(result)

        %{
          status: status,
          exit_status: result.exit_status,
          wall_ms: result.duration_ms,
          log_path: log,
          output: result.output_tail
        }

      {:error, reason} ->
        %{status: "unavailable", reason: inspect(reason)}
    end
  end

  defp trial_status(result) do
    status =
      cond do
        result.timed_out ->
          "timeout"

        result.exit_status == 0 ->
          "survived"

        String.contains?(result.output_tail, [
          "Compilation error",
          "SyntaxError",
          "TokenMissingError",
          "CompileError"
        ]) ->
          "invalid"

        Regex.match?(~r/\d+\) test /, result.output_tail) ->
          "killed"

        true ->
          "unavailable"
      end

    status
  end

  defp command(report, file) do
    survivors =
      for trial <- report.trials, trial.status == "survived" do
        Report.finding(
          "mutation",
          "survived",
          trial.path,
          trial.line,
          "#{trial.original} -> #{trial.replacement} survived at column #{trial.column}. Tests: #{Enum.join(trial.tests, ", ")}. Add an assertion distinguishing the changed outcome or record explicit equivalent-mutant evidence by location and reasoning in the Build report. Mutation-ignore comments do not suppress trials."
        )
      end

    summary =
      Report.finding(
        "mutation",
        "qualification",
        nil,
        nil,
        "Checked #{length(report.trials)}/#{report.eligible} eligible mutations in #{report.wall_ms}ms; complete=#{report.complete}. Scope: #{report.operator_scope}. Report: #{file}. Advisory; calibrate on real Builds before choosing a blocking policy.",
        :note
      )

    Report.command("mutation", survivors ++ [summary])
  end
end
