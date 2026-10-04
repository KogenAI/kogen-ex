defmodule Kogen.State.Event do
  @moduledoc "A decoded run-journal event used by Kernel reports."

  @enforce_keys [:event]
  defstruct [
    :event,
    :recipe,
    :roles,
    :phase,
    :name,
    :stage,
    :class,
    :reason,
    :detail,
    :path,
    :declared_domains,
    :test_ids,
    :seed,
    :status,
    :result,
    :approval_commit,
    :base_sha,
    :ledger,
    :receipts,
    :model,
    :effort,
    :started_at,
    :finished_at,
    :credential_source,
    :credential_label,
    :tokens,
    :wall_ms
  ]

  @type t :: %__MODULE__{
          event: String.t(),
          recipe: String.t() | nil,
          roles: map() | nil,
          phase: String.t() | nil,
          name: String.t() | nil,
          stage: String.t() | nil,
          class: String.t() | nil,
          reason: String.t() | nil,
          detail: String.t() | nil,
          path: String.t() | nil,
          declared_domains: [String.t()] | nil,
          test_ids: [String.t()] | nil,
          seed: non_neg_integer() | nil,
          status: term(),
          result: term(),
          approval_commit: String.t() | nil,
          base_sha: String.t() | nil,
          ledger: term(),
          receipts: term(),
          model: String.t() | nil,
          effort: String.t() | nil,
          started_at: integer() | nil,
          finished_at: integer() | nil,
          credential_source: String.t() | nil,
          credential_label: String.t() | nil,
          tokens: term(),
          wall_ms: non_neg_integer() | nil
        }
end
