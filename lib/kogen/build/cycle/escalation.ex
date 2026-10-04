defmodule Kogen.Build.Cycle.Escalation do
  @moduledoc false

  alias Kogen.Build.Cycle.State
  alias Kogen.Build.Recipe

  @summary_limit 1_000

  @spec findings(map()) :: [String.t()]
  def findings(%{findings: findings}) when is_list(findings),
    do: Enum.filter(findings, &is_binary/1)

  def findings(_data), do: []

  @spec prepare(State.t(), atom()) :: {:ok, State.t(), map()} | :disabled
  def prepare(%State{escalation_used?: false} = state, trigger) do
    case Recipe.escalation(state.recipe) do
      %{on: triggers, model: model, effort: effort} = _config
      when is_list(triggers) and is_binary(model) and is_binary(effort) ->
        if trigger in triggers do
          summary = summary(trigger, state.last_gate_findings)
          next = next_attempt(state)

          {:ok, next,
           %{
             attempt: :escalation,
             trigger: trigger,
             summary: summary,
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

  def prepare(_state, _trigger), do: :disabled

  defp next_attempt(state) do
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
        attempt: :escalation,
        escalation_used?: true,
        result: nil
    }
  end

  defp summary(trigger, findings) do
    detail =
      case Enum.take(findings, 5) do
        [] -> "No gate findings were recorded."
        lines -> Enum.map_join(lines, "\n", &clip(&1, 180))
      end

    ["The builder attempt stopped after #{trigger}.", "Last deterministic gate findings:", detail]
    |> Enum.join("\n")
    |> clip(@summary_limit)
  end

  defp clip(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit), else: text
  end
end
