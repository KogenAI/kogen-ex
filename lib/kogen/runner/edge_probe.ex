defmodule Kogen.Runner.EdgeProbe do
  @moduledoc false

  # The ladder's opt-in edge probe. Once the first green Candidates exist, one call on the
  # Sol high model writes black-box edge tests from the verbatim Request. They run
  # against every green Candidate in a scratch copy; tests that fail on all of them are
  # discarded as possibly wrong, and the kept tests each Candidate passes become its
  # `edge_passed` for the selector. A lone green Candidate that fails edge tests gets one
  # repair round on a copy; the repaired Candidate competes with the original. The probe only
  # ranks: it never blocks landing.

  import Kogen.Runner.ScratchTests, only: [label: 1]

  alias Kogen.Build.Recipe
  alias Kogen.Build.Selector
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.ProviderError
  alias Kogen.Contracts.RolePrompt
  alias Kogen.Contracts.Stack
  alias Kogen.Engine.Build.GateSupport
  alias Kogen.Engine.Build.Session
  alias Kogen.Harness
  alias Kogen.Runner.EdgeTests
  alias Kogen.Runner.ScratchTests
  alias Kogen.State

  @default_budget_ms 180_000

  @type pair :: {map(), Session.t()}
  @typedoc "Runs one repair round on a copy of a green pair with the given findings."
  @type repair :: (pair(), String.t() -> pair() | nil)

  @doc """
  Probes the green pairs once per Build when the recipe asks for it. Returns the session
  (marked probed) and the pairs with edge metrics, plus a repaired pair when one was made.
  """
  @spec run(Session.t(), [pair()], repair()) :: {Session.t(), [pair()]}
  def run(%Session{} = session, pairs, repair) do
    if Recipe.edge_tests?(session.request.recipe) and not match?(%{probed: true}, session.edge) and
         Enum.any?(pairs, &green?/1) do
      probe(%{session | edge: %{probed: true}}, pairs, repair)
    else
      {session, pairs}
    end
  end

  defp probe(session, pairs, repair) do
    started = now()

    with {:ok, spec} <- ScratchTests.test_command(session),
         {:ok, suite} <- generate(session) do
      probe_run = %{spec: spec, suite: suite, deadline: now() + budget_ms(session)}
      green = Enum.filter(pairs, &green?/1)

      results =
        Map.new(green, fn {outcome, member} -> {outcome.attempt, test(member, probe_run)} end)

      {pairs, results, repaired} = maybe_repair(pairs, green, results, repair, probe_run)
      finish(session, pairs, results, %{suite: suite, repaired: repaired, started: started})
    else
      {:error, reason} ->
        record(session, %{status: :unavailable, reason: reason, wall_ms: now() - started})
        {session, pairs}
    end
  end

  defp generate(session) do
    case session.intent.request do
      request when is_binary(request) and request != "" -> ask(session, request)
      _missing -> {:error, :no_request}
    end
  end

  defp ask(session, request) do
    started = now()
    {model, effort} = {"gpt-6.1-sol", "high"}
    opts = GateSupport.harness_options(session)
    opts = %{opts | models: Map.put(opts.models, :edge_writer, {model, effort})}

    text = EdgeTests.input(request, EdgeTests.module_names(session.workdir))

    call = %RolePrompt{
      stage: :edge,
      role: :edge_writer,
      instructions: EdgeTests.instructions(Stack.detect(session.project.root)),
      text: text
    }

    case Harness.ask(opts, call) do
      {:ok, %{text: reply, usage: usage}} ->
        State.record(session.run, %{
          event: :model_stage,
          stage: :edge,
          model: model,
          effort: effort,
          attempt: session.attempt,
          tokens: usage,
          wall_ms: now() - started
        })

        EdgeTests.parse(reply, Stack.detect(session.project.root))

      {:error, %ProviderError{} = error} ->
        {:error, {:provider, error.class}}

      {:error, reason} ->
        {:error, {:edge_call_failed, inspect(reason)}}
    end
  end

  defp test(member, %{spec: spec, suite: suite, deadline: deadline}) do
    remaining = deadline - now()

    if remaining <= 0 do
      %{result: :timeout, failed: suite.names, output: ""}
    else
      stack = Stack.detect(member.project.root)
      test_path = "test/kogen_edge/edge_probe_test" <> Stack.extension(stack)

      member
      |> ScratchTests.run(spec, %{test_path => suite.source}, [test_path],
        timeout_ms: min(spec.timeout_ms, remaining),
        extra: EdgeTests.run_arguments(stack),
        name: "edge-probe"
      )
      |> test_result(suite.names)
    end
  end

  defp test_result({:ok, %ProcResult{timed_out: true}}, names),
    do: %{result: :timeout, failed: names, output: ""}

  defp test_result({:ok, %ProcResult{} = result}, names) do
    output = full_output(result)
    summary = ScratchTests.summary(output)
    run = if summary, do: :ran, else: :error
    %{result: run, failed: EdgeTests.failed(output, names, summary), output: output}
  end

  defp test_result({:error, _reason}, names), do: %{result: :error, failed: names, output: ""}

  # The log holds the whole run; the tail may have lost early failure headers.
  defp full_output(%ProcResult{log_path: path, output_tail: tail}) when is_binary(path) do
    case File.read(path) do
      {:ok, output} -> output
      {:error, _reason} -> tail
    end
  end

  defp full_output(%ProcResult{output_tail: tail}), do: tail

  # One repair round when a lone green Candidate fails edge tests that ran.
  defp maybe_repair(pairs, [{outcome, _member} = only], results, repair, probe_run) do
    case Map.fetch!(results, outcome.attempt) do
      %{result: :ran, failed: [_ | _] = failed, output: output} ->
        only
        |> repair.(EdgeTests.findings(failed, output))
        |> repaired(pairs, results, probe_run)

      _passed_or_unusable ->
        {pairs, results, nil}
    end
  end

  defp maybe_repair(pairs, _green, results, _repair, _probe_run), do: {pairs, results, nil}

  defp repaired(nil, pairs, results, _probe_run), do: {pairs, results, nil}

  defp repaired({%{status: :green} = outcome, member}, pairs, results, probe_run) do
    case test(member, probe_run) do
      %{result: :timeout} ->
        unverified = %{outcome | status: :failed, reason: :edge_unverified}
        {pairs ++ [{unverified, member}], results, unverified}

      result ->
        {pairs ++ [{outcome, member}], Map.put(results, outcome.attempt, result), outcome}
    end
  end

  defp repaired({outcome, member}, pairs, results, _probe_run),
    do: {pairs ++ [{outcome, member}], results, outcome}

  defp finish(session, pairs, results, %{suite: suite, repaired: repaired, started: started}) do
    timeout? = Enum.any?(results, fn {_attempt, result} -> result.result == :timeout end)
    kept = if timeout?, do: [], else: kept(suite.names, Map.values(results))
    scored = if timeout?, do: pairs, else: Enum.map(pairs, &score(&1, results, kept))
    green = for {%{status: :green} = outcome, _member} <- scored, do: outcome

    record(session, %{
      status: if(timeout?, do: :timeout, else: :complete),
      generated: suite.generated,
      kept: length(kept),
      wall_ms: now() - started,
      attempt: label(Selector.best(green).attempt),
      matrix: Enum.map(results, &cell(&1, suite.names, kept)),
      repair: repair_summary(repaired)
    })

    {session, scored}
  end

  # Tests that failed on every probed Candidate may be wrong; the rest are kept.
  defp kept(names, results) do
    failed_everywhere =
      results
      |> Enum.map(&MapSet.new(&1.failed))
      |> Enum.reduce(&MapSet.intersection/2)

    Enum.reject(names, &MapSet.member?(failed_everywhere, &1))
  end

  defp score({%{status: :green} = outcome, member} = pair, results, kept) do
    case Map.fetch(results, outcome.attempt) do
      {:ok, result} ->
        metrics =
          outcome.metrics
          |> Map.put(:edge_passed, length(kept -- result.failed))
          |> Map.put_new(:gate_warnings, ScratchTests.warnings(member))

        {%{outcome | metrics: metrics}, member}

      :error ->
        pair
    end
  end

  defp score(pair, _results, _kept), do: pair

  defp cell({attempt, result}, names, kept) do
    %{
      candidate: label(attempt),
      result: result.result,
      passed: length(names -- result.failed),
      kept_passed: length(kept -- result.failed),
      failed: result.failed
    }
  end

  defp repair_summary(nil), do: nil

  defp repair_summary(outcome),
    do: %{attempt: label(outcome.attempt), result: outcome.status, reason: outcome.reason}

  defp record(session, data) do
    State.record(session.run, Map.merge(%{event: :edge_probe}, data))
  end

  defp green?({%{status: status}, _member}), do: status == :green

  defp budget_ms(session) do
    case Recipe.ladder(session.request.recipe) do
      %{edge_ms: ms} when is_integer(ms) and ms > 0 -> ms
      _default -> @default_budget_ms
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
