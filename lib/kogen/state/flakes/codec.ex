defmodule Kogen.State.Flakes.Observation do
  @moduledoc false
  defstruct [
    :kind,
    :run_id,
    :seed,
    :classification,
    :path,
    :evidence,
    test_ids: [],
    excused: [],
    cost_ms: 0,
    domains: [],
    base_ids: [],
    candidate_ids: []
  ]

  @type t :: %__MODULE__{}
end

defmodule Kogen.State.Flakes.Codec do
  @moduledoc false
  alias Kogen.State.Flakes.Observation

  @spec observation(String.t(), map()) :: Observation.t()
  def observation(run_id, event) do
    detail = if is_map(event.detail), do: event.detail, else: %{}

    %Observation{
      kind: event.event,
      run_id: run_id,
      seed: event.seed,
      test_ids: event.test_ids || [],
      classification: Map.get(detail, "classification", "legacy_unknown"),
      excused: Map.get(detail, "excused_test_ids", event.test_ids || []),
      cost_ms: Map.get(detail, "retry_cost_ms", 0),
      domains: Map.get(detail, "domains", []),
      path: Map.get(detail, "path"),
      base_ids: Map.get(detail, "base_failed_test_ids", []),
      candidate_ids: Map.get(detail, "candidate_failed_test_ids", []),
      evidence: detail
    }
  end
end
