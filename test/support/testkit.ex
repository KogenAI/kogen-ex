defmodule Kogen.Testkit do
  @moduledoc false
  use Boundary,
    deps: [Kogen.Contracts, Kogen.Intent, Kogen.Kernel, ExUnit],
    exports: [
      BenchmarkAuth,
      BudgetFormatter,
      Case,
      FakeResponsesServer,
      Git,
      HarnessScriptedProvider,
      IntentFixture,
      Rails,
      Temp
    ]
end
