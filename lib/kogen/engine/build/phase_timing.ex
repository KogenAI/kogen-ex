defmodule Kogen.Engine.Build.PhaseTiming do
  @moduledoc false

  alias Kogen.Engine.Build.Session
  alias Kogen.State

  @spec measure(Session.t(), String.t(), String.t(), (-> result)) :: result when result: term()
  def measure(%Session{} = session, phase, name, operation)
      when is_binary(phase) and is_binary(name) and is_function(operation, 0) do
    started_wall = System.system_time(:millisecond)
    started_mono = System.monotonic_time(:millisecond)

    try do
      operation.()
    after
      record(
        session.run,
        phase,
        name,
        elapsed(started_mono),
        started_wall,
        System.system_time(:millisecond)
      )
    end
  end

  @spec record(
          Kogen.State.Run.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          integer(),
          integer()
        ) ::
          :ok | {:error, term()}
  def record(run, phase, name, wall_ms, started_at, finished_at) do
    State.record(run, %{
      event: :phase_timing,
      phase: phase,
      name: name,
      wall_ms: wall_ms,
      started_at: started_at,
      finished_at: finished_at
    })
  end

  defp elapsed(started_at), do: max(System.monotonic_time(:millisecond) - started_at, 0)
end
