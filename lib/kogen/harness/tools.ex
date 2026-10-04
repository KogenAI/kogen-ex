defmodule Kogen.Harness.Tools do
  @moduledoc false

  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness.Opts
  alias Kogen.Harness.ToolingContext
  alias Kogen.Tooling.Codec
  alias Kogen.Tooling.ToolResult
  alias Kogen.Tooling.Tools, as: BuilderTools

  @spec run(Opts.t(), ToolCall.t(), [Codec.tool_name()]) :: ToolResult.t()
  def run(%Opts{} = opts, call, allowed_tools) do
    BuilderTools.run(ToolingContext.from_opts(opts), call, allowed_tools)
  end

  @spec run_read_only(Opts.t(), ToolCall.t()) :: ToolResult.t()
  def run_read_only(%Opts{} = opts, call),
    do: BuilderTools.run_read_only(ToolingContext.from_opts(opts), call)

  @spec diagnose(Opts.t(), Path.t()) :: [String.t()]
  def diagnose(%Opts{} = opts, relative_path) do
    BuilderTools.diagnose(ToolingContext.from_opts(opts), relative_path)
  end
end
