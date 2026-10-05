defmodule Kogen.Shaper do
  @moduledoc "Creates and deterministically validates an Intent and its acceptance test."
  use Boundary,
    deps: [
      Kogen.Contracts,
      Kogen.Checks,
      Kogen.Harness,
      Kogen.Intent,
      Kogen.Proc,
      Kogen.Project,
      Kogen.Resilience
    ],
    exports: [Request, Result]

  alias Kogen.Shaper.Request
  alias Kogen.Shaper.Result

  @spec shape(Request.t()) :: {:ok, Result.t()} | {:error, term()}
  def shape(%Request{} = request), do: Kogen.Shaper.Runner.run(request)
end
