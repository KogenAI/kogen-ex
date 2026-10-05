defmodule Kogen.Engine.Build.GateSupportTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.GateSupport
  alias Kogen.Harness.Result

  test "developer caps remain explicit candidate failure reasons" do
    for reason <- [:turn_cap, :wall_cap] do
      assert {%Failure{class: :candidate, reason: ^reason, detail: detail}, returned_detail} =
               GateSupport.gate_failure(%Result{
                 outcome: reason,
                 gate: nil,
                 items: [],
                 turns: 60,
                 usage: %{},
                 transcript_path: "/tmp/transcript.jsonl"
               })

      assert returned_detail == detail
      assert detail =~ if(reason == :turn_cap, do: "turn cap", else: "wall-clock cap")
    end
  end
end
