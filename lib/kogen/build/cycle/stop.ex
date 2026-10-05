defmodule Kogen.Build.Cycle.Stop do
  @moduledoc false

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
