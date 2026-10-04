defmodule Kogen.Harness.ShaperTools do
  @moduledoc false

  alias Kogen.Harness.Opts
  alias Kogen.Harness.ToolingContext
  alias Kogen.Tooling.ShaperTools, as: BuilderShaperTools
  alias Kogen.Tooling.ToolResult

  @spec run(Opts.t(), Kogen.Contracts.ToolCall.t(), [String.t()]) :: ToolResult.t()
  def run(%Opts{} = opts, call, allowed_paths) do
    BuilderShaperTools.run(ToolingContext.from_opts(opts), call, allowed_paths)
  end
end
