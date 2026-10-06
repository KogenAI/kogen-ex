defmodule Kogen.Testkit.BudgetFormatter do
  @moduledoc "Warns when the ExUnit suite takes at least ten seconds; never fails for elapsed time."
  use GenServer

  @warning_us 10_000_000

  @impl GenServer
  def init(_opts), do: {:ok, nil}

  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{time: time} = test}, slowest) do
    if is_nil(slowest) or time > slowest.time, do: {:noreply, test}, else: {:noreply, slowest}
  end

  def handle_cast({:suite_finished, %{run: run_us}}, state) when run_us >= @warning_us do
    IO.puts(
      :stderr,
      "WARNING: ExUnit suite took #{div(run_us, 1_000)} ms (10 s advisory budget); " <>
        "slowest stage: tests; slowest test: #{slowest(state)}. Correctness is unchanged."
    )

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp slowest(nil), do: "unavailable"
  defp slowest(test), do: "#{inspect(test.module)} #{test.name} #{div(test.time, 1_000)} ms"
end
