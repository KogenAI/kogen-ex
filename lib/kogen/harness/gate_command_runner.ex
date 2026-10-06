defmodule Kogen.Harness.Gate.CommandRunner do
  @moduledoc false

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Harness.GateCommand
  alias Kogen.Harness.Opts
  alias Kogen.Harness.PhaseTiming
  alias Kogen.Harness.ToolingContext
  alias Kogen.Tooling.Command
  alias Kogen.Tooling.Error

  @spec run(Opts.t(), CheckSpec.t(), [String.t()], pos_integer(), atom(), String.t()) ::
          GateCommand.t()
  def run(opts, spec, argv, timeout_ms, kind, suffix) do
    phase_name = "gate_#{kind}:#{spec.name}#{suffix}"

    PhaseTiming.measure(opts, "build", phase_name, fn ->
      case Command.run(
             ToolingContext.from_opts(opts),
             argv,
             timeout_ms,
             "gate-#{kind}-#{spec.name}#{suffix}"
           ) do
        {:ok, result} ->
          %GateCommand{
            name: spec.name,
            duration_ms: result.duration_ms,
            argv: argv,
            exit_status: result.exit_status,
            timed_out: result.timed_out,
            output: clip_tail(result.output_tail),
            log_path: result.log_path
          }

        {:error, %Error{} = error} ->
          %GateCommand{name: spec.name, exit_status: nil, timed_out: false, output: error.detail}
      end
    end)
  end

  defp clip_tail(output) do
    if String.valid?(output) do
      if String.length(output) > 10_000,
        do: String.slice(output, String.length(output) - 10_000, 10_000),
        else: output
    else
      tail = binary_part(output, max(byte_size(output) - 7_400, 0), min(byte_size(output), 7_400))
      "[non-UTF-8 output tail, base64 encoded]\n" <> Base.encode64(tail)
    end
  end
end
