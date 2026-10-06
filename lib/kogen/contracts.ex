defmodule Kogen.Contracts do
  @moduledoc "Shared data structures and behaviours used at Kogen's domain boundaries."
  use Boundary,
    deps: [],
    exports: [
      AcceptanceItem,
      CheckSpec,
      CheckBaseline,
      CheckOutput,
      CommandExit,
      Failure,
      Finding,
      GateTiming,
      GateTiming.Codec,
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
      RolePrompt,
      ShapeWarning,
      ShapeWarningCodec,
      Stack,
      ToolCall,
      Yaml
    ]
end
