defmodule Kogen.Queue.IntentStatus do
  @moduledoc """
  One Intent's derived state. `approved_at` (Unix seconds) orders the queue; `landed_index` is
  0 for the most recent landing; `detail` is a failed Build's reason or a running Build's stage.
  """

  @enforce_keys [:slug, :status, :run_id, :landed_sha]
  defstruct @enforce_keys ++ [approved_at: nil, landed_index: nil, detail: nil, started_at: nil]

  @type t :: %__MODULE__{
          slug: String.t(),
          status: Kogen.State.status(),
          run_id: String.t() | nil,
          landed_sha: String.t() | nil,
          approved_at: integer() | nil,
          landed_index: non_neg_integer() | nil,
          detail: String.t() | nil,
          started_at: integer() | nil
        }
end
