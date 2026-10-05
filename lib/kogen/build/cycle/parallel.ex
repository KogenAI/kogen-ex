defmodule Kogen.Build.Cycle.Parallel do
  @moduledoc false

  # A plan rated hard runs the ladder's leading rungs at once on separate fresh Candidates.
  # The Build continues from the better one: a green winner goes on to commit, otherwise the
  # ladder resumes after the parallel rungs with the winner's findings.

  alias Kogen.Build.Cycle.Escalation
  alias Kogen.Build.Cycle.State
  alias Kogen.Build.Recipe
  alias Kogen.Build.Selector

  @type outcome :: %{
          required(:index) => non_neg_integer(),
          required(:attempt) => State.attempt(),
          required(:status) => :green | :failed,
          required(:reason) => term(),
          required(:findings) => [String.t()],
          required(:metrics) => map()
        }

  @spec start(State.t(), map()) :: {:ok, State.t(), [term()]} | :sequential
  def start(%State{sub?: false, rung: 0} = state, %{difficulty: :hard}) do
    with %{parallel_on_hard: count} when count >= 2 <- Recipe.ladder(state.recipe),
         members when length(members) >= 2 <- members(state.recipe, count) do
      attempts = Enum.map(members, & &1.attempt)

      {:ok, %{state | stage: :parallel},
       [
         {:record, %{event: :parallel_started, attempts: attempts}},
         {:parallel, %{members: members}}
       ]}
    else
      _sequential -> :sequential
    end
  end

  def start(_state, _data), do: :sequential

  @doc "Chooses the better outcome; returns the adopted state and whether it is green."
  @spec done(State.t(), [outcome()]) :: {State.t(), outcome(), [term()]}
  def done(%State{} = state, [_ | _] = outcomes) do
    winner = Selector.best(outcomes)
    losers = Enum.reject(outcomes, &(&1.attempt == winner.attempt))

    summaries =
      for %{status: :failed} = loser <- losers,
          do: Escalation.summary(loser.attempt, loser.reason, loser.findings)

    next = %{
      state
      | attempt: winner.attempt,
        rung: outcomes |> Enum.map(& &1.index) |> Enum.max(),
        rung_summaries: state.rung_summaries ++ summaries,
        last_gate_findings: winner.findings
    }

    record =
      {:record,
       %{
         event: :parallel_selected,
         attempt: winner.attempt,
         result: winner.status,
         outcomes: Enum.map(outcomes, &Map.take(&1, [:attempt, :status, :reason, :metrics]))
       }}

    {next, winner, [record, {:adopt, winner.attempt}]}
  end

  defp members(recipe, count) do
    Enum.flat_map(0..(count - 1), fn index ->
      case Recipe.rung(recipe, index) do
        nil -> []
        rung -> [%{index: index, attempt: Recipe.rung_attempt(recipe, index), rung: rung}]
      end
    end)
  end
end
