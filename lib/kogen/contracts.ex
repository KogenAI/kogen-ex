defmodule Kogen.Contracts do
  @moduledoc "Shared data structures and behaviours used at Kogen's domain boundaries."
  use Boundary,
    deps: [],
    exports: [
      AcceptanceItem,
      CheckSpec,
      CheckBaseline,
      CommandExit,
      Failure,
      Intent,
      JSON,
      ModelRequest,
      ModelResponse,
      MiseEnvironment,
      ProcPort,
      ProcResult,
      Project,
      ProviderError,
      ProviderPort,
      Receipt,
      Redact,
      ShapeWarning,
      ShapeWarningCodec,
      ToolCall,
      Yaml
    ]
end
