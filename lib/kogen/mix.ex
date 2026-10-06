defmodule Kogen.Mix do
  @moduledoc "Boundary for repository Mix tasks and development-time tooling."
  use Boundary,
    deps: [Mix, Kogen.Contracts, Kogen.Provider, Kogen.CheckLearning, Kogen.Kernel],
    exports: []
end
