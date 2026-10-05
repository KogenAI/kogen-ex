defmodule Kogen.Contracts.DeveloperFailure do
  @moduledoc false
  alias Kogen.Contracts.Failure

  def from_developer(%{outcome: :done}), do: {nil, nil}

  def from_developer(%{outcome: :gate_environment, gate: gate}) do
    detail = gate_detail(gate, "The done gate could not complete its checks.")
    {%Failure{class: :environment, reason: :check_unavailable, detail: detail}, detail}
  end

  def from_developer(%{outcome: reason}) when reason in [:turn_cap, :wall_cap] do
    detail =
      case reason do
        :turn_cap -> "Developer exhausted its turn cap."
        :wall_cap -> "Developer exhausted its wall-clock cap."
      end

    {%Failure{class: :candidate, reason: reason, detail: detail}, detail}
  end

  def from_developer(%{outcome: :gate_red, gate: gate}) do
    detail = gate_detail(gate, "Harness done gate failed.")
    {%Failure{class: :candidate, reason: :done_gate_red, detail: detail}, detail}
  end

  defp gate_detail(%{failures: failures}, fallback) when is_list(failures),
    do: if(failures == [], do: fallback, else: Enum.join(failures, "\n"))

  defp gate_detail(_gate, fallback), do: fallback
end
