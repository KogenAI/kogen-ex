defmodule Kogen.Build do
  @moduledoc "Pure build-cycle decisions and their effect data."
  use Boundary,
    deps: [Kogen.Contracts, Kogen.Resilience],
    exports: [
      Cycle,
      Cycle.State,
      Demotion,
      GateMetrics,
      GateSummary,
      Recipe,
      Selector,
      Verification
    ]
end
