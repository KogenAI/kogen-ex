defmodule Kogen.Resilience do
  @moduledoc "Owns the provider retry, backoff and model-fallback policy shared by every model stage."
  use Boundary, deps: [Kogen.Contracts], exports: [Policy, ProviderCall, Retry, RequestLog]
end
