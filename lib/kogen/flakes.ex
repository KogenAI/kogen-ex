defmodule Kogen.Flakes do
  @moduledoc "Same-seed flake classification with durable evidence and conservative excusal."
  use Boundary, deps: [Kogen.Contracts, Kogen.Checks, Kogen.Workspace]

  alias Kogen.Checks.Feedback
  alias Kogen.Contracts.ProcResult
  alias Kogen.Flakes.Evidence

  @max_excused_tests 2

  @spec classify(map(), map(), map(), function()) :: {map(), [map()]}
  def classify(opts, spec, classification, runner) do
    snapshot = Evidence.snapshot(opts)
    started = System.monotonic_time(:millisecond)
    retry = runner.(classification.retry_argv, classification.deadline, "-retry")
    base = run_base(opts, classification.retry_argv, classification.deadline, spec.timeout_ms)
    cost = System.monotonic_time(:millisecond) - started
    base_ids = base_failure_ids(base, opts.workdir)

    excused =
      if passed?(retry),
        do:
          fit_cap(
            Enum.filter(classification.test_ids, &(&1 in base_ids)),
            opts.flake_excused_test_ids
          ),
        else: []

    data = %{
      retry: retry,
      base: base,
      base_ids: base_ids,
      excused: excused,
      cost: cost,
      snapshot: snapshot
    }

    case Evidence.persist(opts, classification, data) do
      {:ok, evidence} ->
        outcome(opts, classification, data, evidence)

      {:error, reason} ->
        {%{
           classification.command
           | output:
               classification.command.output <>
                 "\nFlake evidence could not be recorded; failure remains red: #{inspect(reason)}"
         }, []}
    end
  end

  defp outcome(opts, classification, data, evidence) do
    original = classification.command
    ids = classification.test_ids
    retry_ids = Feedback.failed_test_ids(data.retry.output, opts.workdir)

    cond do
      passed?(data.retry) ->
        excusal(classification, data, evidence)

      same_ids?(ids, retry_ids) and same_ids?(ids, data.base_ids) ->
        detail =
          "Environment failure (base-red): the same ExUnit failures reproduced on the clean base under the configured sandbox; skipped Developer repair for #{inspect(ids)}. Evidence: #{evidence.path}"

        {%{original | base_red?: true, output: original.output <> "\n" <> detail}, []}

      true ->
        {%{
           original
           | output:
               original.output <>
                 "\nSame-seed rerun still failed: #{inspect(ids)} (seed #{classification.seed}). Evidence: #{evidence.path}\n#{data.retry.output}"
         }, []}
    end
  end

  defp excusal(classification, data, evidence) do
    original = classification.command
    ids = classification.test_ids
    remaining = ids -- data.excused

    event =
      if data.excused == [],
        do: [],
        else: [%{test_ids: data.excused, seed: classification.seed, detail: evidence}]

    detail =
      if remaining == [],
        do: "Same-seed rerun passed; confirmed base flakes excused: #{inspect(data.excused)}",
        else:
          "Same-seed rerun passed, but these tests remain Candidate failures: #{inspect(remaining)}"

    command = %{
      original
      | output:
          original.output <>
            "\n#{detail} (seed #{classification.seed}). Evidence: #{evidence.path}\n#{data.retry.output}"
    }

    command =
      if remaining == [], do: %{command | exit_status: 0, timed_out: false}, else: command

    {command, event}
  end

  defp run_base(%{base_test: base_test}, argv, deadline, timeout)
       when is_function(base_test, 2) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0,
      do: {:error, :deadline_reached},
      else: base_test.(argv, min(timeout, remaining))
  end

  defp run_base(_opts, _argv, _deadline, _timeout), do: {:error, :base_test_unavailable}

  defp base_failure_ids(
         {:ok, %ProcResult{exit_status: status, timed_out: false, output_tail: output}},
         root
       )
       when is_integer(status) and status != 0, do: Feedback.failed_test_ids(output, root)

  defp base_failure_ids(_result, _root), do: []

  defp fit_cap(eligible, previously_excused) do
    previous = MapSet.new(previously_excused)
    repeat = Enum.filter(eligible, &MapSet.member?(previous, &1))
    new = Enum.reject(eligible, &MapSet.member?(previous, &1))
    repeat ++ Enum.take(new, max(@max_excused_tests - MapSet.size(previous), 0))
  end

  defp same_ids?(left, right), do: left != [] and MapSet.new(left) == MapSet.new(right)
  defp passed?(%{exit_status: 0, timed_out: false}), do: true
  defp passed?(_command), do: false
end
