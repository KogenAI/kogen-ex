defmodule Kogen.Build do
  @moduledoc "Pure build-cycle decisions and their effect data."
  use Boundary,
    deps: [Kogen.Contracts],
    exports: [Cycle, Cycle.State, Demotion, GateSummary, Recipe, Selector]
end
