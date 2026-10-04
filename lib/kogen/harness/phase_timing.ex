defmodule Kogen.Harness.PhaseTiming do
  @moduledoc false

  alias Kogen.Harness.Opts

  @spec measure(Opts.t(), String.t(), String.t(), (-> result)) :: result when result: term()
  def measure(%Opts{} = opts, phase, name, operation)
      when is_binary(phase) and is_binary(name) and is_function(operation, 0) do
    started_wall = System.system_time(:millisecond)
    started_mono = System.monotonic_time(:millisecond)

    try do
      operation.()
    after
      wall_ms = max(System.monotonic_time(:millisecond) - started_mono, 0)
      finished_at = System.system_time(:millisecond)

      if is_function(opts.phase_recorder, 5),
        do: opts.phase_recorder.(phase, name, wall_ms, started_wall, finished_at)
    end
  end
end
