defmodule Kogen.Tooling do
  @moduledoc "Executes the bounded file and shell tools exposed to Builder stages."
  use Boundary,
    deps: [Kogen.Contracts, Kogen.Proc],
    exports: [
      Codec,
      Command,
      Context,
      Error,
      Mutations,
      Paths,
      ReadSearch,
      ShaperTools,
      ToolArgs,
      ToolResult,
      Tools
    ]
end
