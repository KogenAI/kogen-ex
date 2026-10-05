defmodule Kogen.Build.Cycle.State do
  @moduledoc false

  alias Kogen.Build.Recipe

  @enforce_keys [
    :approval,
    :recipe,
    :stage,
    :repairs_left,
    :repair_cap,
    :last_failed_test_count,
    :progress_repair_used?,
    :provider_retries,
    :last_tree,
    :repair_tree,
    :pending_land,
    :attempt,
    :escalation_used?,
    :last_gate_findings,
    :last_gate_summary,
    :result
  ]
  defstruct @enforce_keys ++
              [
                rung: 0,
                rung_summaries: [],
                last_failure_count: nil,
                pending_gate: nil,
                audit_source: nil,
                sub?: false
              ]

  @type attempt :: :builder | :escalation | String.t()
  @type t :: %__MODULE__{
          approval: term(),
          recipe: Recipe.t(),
          stage: atom(),
          repairs_left: non_neg_integer(),
          repair_cap: non_neg_integer(),
          last_failed_test_count: non_neg_integer() | nil,
          progress_repair_used?: boolean(),
          provider_retries: non_neg_integer(),
          last_tree: String.t() | nil,
          repair_tree: String.t() | nil,
          pending_land: boolean(),
          attempt: attempt(),
          escalation_used?: boolean(),
          last_gate_findings: [String.t()],
          last_gate_summary: map() | nil,
          result: {atom(), term()} | nil,
          rung: non_neg_integer(),
          rung_summaries: [String.t()],
          last_failure_count: non_neg_integer() | nil,
          pending_gate: map() | nil,
          audit_source: :done_gate | :check | nil,
          sub?: boolean()
        }
end
