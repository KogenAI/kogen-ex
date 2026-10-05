defmodule Kogen.Runner.CrossCheck do
  @moduledoc false

  # When two or more parallel members are green, each runs the tests the others added or
  # changed, in a scratch copy of its checkout with the gate's test command and timeout. A
  # green outcome gains `cross_passed` (the others' tests it passed) and `gate_warnings` for
  # the selector. The whole cross-check has one time budget; when it runs out the outcomes
  # are returned unchanged, so the selector falls back to the smaller diff.

  import Kogen.Runner.ScratchTests, only: [label: 1, test_file?: 1]

  alias Kogen.Build.Recipe
  alias Kogen.Contracts.ProcResult
  alias Kogen.Engine.Build.CandidateSnapshot
  alias Kogen.Engine.Build.Session
  alias Kogen.Runner.ScratchTests

  @default_budget_ms 300_000

  @type cell :: %{
          candidate: String.t(),
          tests_of: String.t(),
          tests: non_neg_integer(),
          passed: non_neg_integer(),
          result: :ran | :timeout | :error
        }

  @doc "Adds cross-check metrics to green outcomes; also returns the event to record, if any."
  @spec run(Session.t(), [{map(), Session.t()}]) :: {[map()], map() | nil}
  def run(%Session{} = session, pairs) do
    outcomes = Enum.map(pairs, &elem(&1, 0))
    green = Enum.filter(pairs, fn {outcome, _member} -> outcome.status == :green end)

    if length(green) < 2, do: {outcomes, nil}, else: cross_check(session, outcomes, green)
  end

  defp cross_check(session, outcomes, green) do
    with {:ok, spec} <- ScratchTests.test_command(session),
         {:ok, tests} <- all_added_tests(green) do
      cross_check(session, outcomes, green, {spec, tests})
    else
      {:error, reason} -> {outcomes, Map.put(event(:unavailable, 0, []), :reason, reason)}
    end
  end

  defp cross_check(session, outcomes, green, {spec, tests}) do
    started = System.monotonic_time(:millisecond)
    deadline = started + budget_ms(session)

    cells =
      for {outcome, member} <- green,
          {other, _other_member} <- green,
          other.attempt != outcome.attempt,
          Enum.any?(Map.keys(tests[other.attempt]), &test_file?/1),
          reduce: [] do
        cells -> cells ++ [cell(member, outcome, other, tests[other.attempt], spec, deadline)]
      end

    wall_ms = System.monotonic_time(:millisecond) - started

    if Enum.any?(cells, &(&1.result == :timeout)) do
      {outcomes, event(:timeout, wall_ms, cells)}
    else
      {Enum.map(outcomes, &score(&1, cells, green)), event(:complete, wall_ms, cells)}
    end
  end

  defp cell(member, outcome, other, files, spec, deadline) do
    base = %{candidate: label(outcome.attempt), tests_of: label(other.attempt)}
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Map.merge(base, %{tests: 0, passed: 0, result: :timeout})
    else
      paths = files |> Map.keys() |> Enum.filter(&test_file?/1)

      member
      |> ScratchTests.run(spec, files, paths, timeout_ms: min(spec.timeout_ms, remaining))
      |> counts()
      |> Map.merge(base)
    end
  end

  defp counts({:ok, %ProcResult{timed_out: true}}), do: %{tests: 0, passed: 0, result: :timeout}

  defp counts({:ok, %ProcResult{output_tail: output}}) do
    case ScratchTests.summary(output) do
      {tests, passed} -> %{tests: tests, passed: passed, result: :ran}
      nil -> %{tests: 0, passed: 0, result: :error}
    end
  end

  defp counts({:error, _reason}), do: %{tests: 0, passed: 0, result: :error}

  defp score(%{status: :green} = outcome, cells, green) do
    case Enum.find(green, fn {candidate, _member} -> candidate.attempt == outcome.attempt end) do
      {_candidate, member} ->
        passed =
          cells
          |> Enum.filter(&(&1.candidate == label(outcome.attempt)))
          |> Enum.map(& &1.passed)
          |> Enum.sum()

        metrics =
          Map.merge(outcome.metrics, %{
            cross_passed: passed,
            gate_warnings: ScratchTests.warnings(member)
          })

        %{outcome | metrics: metrics}

      nil ->
        outcome
    end
  end

  defp score(outcome, _cells, _green), do: outcome

  defp all_added_tests(green) do
    Enum.reduce_while(green, {:ok, %{}}, fn {outcome, member}, {:ok, acc} ->
      case added_tests(member) do
        {:ok, files} -> {:cont, {:ok, Map.put(acc, outcome.attempt, files)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # The test files and test support the member added or changed, read from its checkout.
  defp added_tests(member) do
    with {:ok, diff} <- CandidateSnapshot.diff(member) do
      files =
        for "+++ b/" <> path <- String.split(diff, "\n"),
            String.starts_with?(path, "test/"),
            {:ok, source} <- [File.read(Path.join(member.workdir, path))],
            into: %{},
            do: {path, source}

      {:ok, files}
    end
  end

  defp budget_ms(session) do
    case Recipe.ladder(session.request.recipe) do
      %{cross_check_ms: ms} when is_integer(ms) and ms > 0 -> ms
      _default -> @default_budget_ms
    end
  end

  defp event(status, wall_ms, cells),
    do: %{event: :cross_check, status: status, wall_ms: wall_ms, matrix: cells}
end
