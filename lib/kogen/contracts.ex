defmodule Kogen.Contracts do
  @moduledoc "Shared data structures and behaviours used at Kogen's domain boundaries."
  use Boundary,
    deps: [],
    exports: [
      AcceptanceItem,
      CheckSpec,
      Failure,
      Intent,
      JSON,
      ModelRequest,
      ModelResponse,
      ProcPort,
      ProcResult,
      Project,
      ProviderError,
      ProviderPort,
      Receipt,
      ShapeWarning,
      ShapeWarningCodec,
      ToolCall,
      Yaml
    ]
end
