defmodule Kogen.Build.Cycle.Escalation do
  @moduledoc false

  # A stopped attempt continues on a fresh Candidate: the recipe's single escalation, or the
  # next ladder rung. The new attempt sees summaries of earlier attempts' last gate findings,
  # never their diffs.

  alias Kogen.Build.Cycle.State
  alias Kogen.Build.Recipe

  @summary_limit 1_000
  @ladder_summary_limit 3_000

  @spec findings(map()) :: [String.t()]
  def findings(%{findings: findings}) when is_list(findings),
    do: Enum.filter(findings, &is_binary/1)

  def findings(_data), do: []

  @spec prepare(State.t(), atom()) :: {:ok, State.t(), map()} | :disabled
  def prepare(%State{sub?: true}, _trigger), do: :disabled

  def prepare(%State{} = state, trigger) do
    case Recipe.ladder(state.recipe) do
      nil -> escalate(state, trigger)
      _ladder -> next_rung(state, trigger)
    end
  end

  @spec summary(term(), term(), [String.t()]) :: String.t()
  def summary(attempt, trigger, findings) do
    detail =
      case Enum.take(findings, 5) do
        [] -> "No gate findings were recorded."
        lines -> Enum.map_join(lines, "\n", &clip(&1, 180))
      end

    ["The #{label(attempt)} attempt stopped after #{trigger_text(trigger)}.", detail]
    |> Enum.join("\nLast deterministic gate findings:\n")
    |> clip(@summary_limit)
  end

  defp escalate(%State{escalation_used?: false} = state, trigger) do
    case Recipe.escalation(state.recipe) do
      %{on: triggers, model: model, effort: effort}
      when is_list(triggers) and is_binary(model) and is_binary(effort) ->
        if trigger in triggers do
          next = %{fresh(state) | attempt: :escalation, escalation_used?: true}

          {:ok, next,
           %{
             attempt: :escalation,
             trigger: trigger,
             summary: summary(:builder, trigger, state.last_gate_findings),
             findings: state.last_gate_findings,
             model: model,
             effort: effort
           }}
        else
          :disabled
        end

      _disabled ->
        :disabled
    end
  end

  defp escalate(_state, _trigger), do: :disabled

  defp next_rung(%State{} = state, trigger) do
    index = state.rung + 1

    case Recipe.rung(state.recipe, index) do
      nil ->
        :disabled

      rung ->
        summaries =
          state.rung_summaries ++ [summary(state.attempt, trigger, state.last_gate_findings)]

        {model, effort} = Recipe.rung_builder(state.recipe, rung)
        attempt = Recipe.rung_attempt(state.recipe, index)
        next = %{fresh(state) | attempt: attempt, rung: index, rung_summaries: summaries}

        {:ok, next,
         %{
           attempt: attempt,
           previous_attempt: state.attempt,
           trigger: trigger,
           summary: ladder_summary(summaries),
           findings: state.last_gate_findings,
           model: model,
           effort: effort,
           rung: rung.name,
           input: rung.input
         }}
    end
  end

  defp fresh(state) do
    %{
      state
      | stage: :develop,
        repairs_left: state.repair_cap,
        last_failed_test_count: nil,
        progress_repair_used?: false,
        provider_retries: 0,
        last_tree: nil,
        repair_tree: nil,
        pending_land: false,
        last_failure_count: nil,
        pending_gate: nil,
        audit_source: nil,
        result: nil
    }
  end

  defp ladder_summary(summaries) do
    clip(
      "Earlier attempts on fresh Candidates did not pass the gate. Their diffs are not " <>
        "shown; start from the base tree.\n\n" <> Enum.join(summaries, "\n\n"),
      @ladder_summary_limit
    )
  end

  defp label(:builder), do: "builder"
  defp label(attempt), do: to_string(attempt)

  defp trigger_text(trigger) when is_atom(trigger), do: Atom.to_string(trigger)
  defp trigger_text(trigger), do: inspect(trigger)

  defp clip(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit), else: text
  end
end
