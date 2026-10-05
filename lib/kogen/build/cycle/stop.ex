defmodule Kogen.Build.Cycle.Stop do
  @moduledoc false

  alias Kogen.Build.Cycle.State

  @doc "Ends the attempt; a main Build also records why it finished."
  @spec finish(State.t(), atom(), term()) :: {State.t(), [term()]}
  def finish(%State{sub?: true} = state, status, reason) do
    {%{state | stage: status, result: {status, reason}, pending_land: false},
     [{:finish, status, reason}]}
  end

  def finish(%State{} = state, status, reason) do
    next = %{state | stage: status, result: {status, reason}, pending_land: false}

    finished = %{
      event: :finished,
      status: status,
      reason: reason,
      attempt: state.attempt,
      gate_summary: state.last_gate_summary,
      stop: summary(state, reason)
    }

    {next, [{:record, finished}, {:finish, status, reason}]}
  end

  @spec summary(map(), term()) :: map()
  def summary(state, reason) when is_map(state) do
    gate = Map.get(state, :last_gate_summary) || %{}
    commands = Map.get(gate, :checks, [])
    checks = Enum.filter(commands, &(Map.get(&1, :kind) == :check))
    fixes = Enum.filter(commands, &(Map.get(&1, :kind) == :fix))
    findings = Map.get(gate, :findings, [])

    %{
      reason: reason,
      reason_text: reason_text(reason),
      attempt: Map.get(state, :attempt),
      repair_cap: Map.get(state, :repair_cap),
      repairs_used: Map.get(state, :repair_cap) - Map.get(state, :repairs_left),
      repairs_remaining: Map.get(state, :repairs_left),
      failed_test_count:
        Map.get(state, :last_failed_test_count) || Map.get(gate, :failed_test_count),
      check_count: length(checks),
      failed_check_count: Enum.count(checks, &(Map.get(&1, :exit_level, 0) > 0)),
      fix_count: length(fixes),
      failed_fix_count: Enum.count(fixes, &(Map.get(&1, :exit_level, 0) > 0)),
      finding_count: Map.get(gate, :finding_count, length(findings))
    }
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)
end
