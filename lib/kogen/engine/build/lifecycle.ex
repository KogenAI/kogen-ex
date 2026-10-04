defmodule Kogen.Engine.Build.Lifecycle do
  @moduledoc false

  alias Kogen.State
  alias Kogen.State.Run

  @spec record_setup_reuse(Run.t(), map()) :: :ok | {:error, term()}
  def record_setup_reuse(_run, %{reused?: false}), do: :ok

  def record_setup_reuse(run, %{reused?: true, key: key, saved_wall_ms: wall_ms}) do
    State.record(run, %{event: :setup_reused, setup_key: key, saved_wall_ms: wall_ms})
  end
end
