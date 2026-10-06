defmodule Kogen.Contracts.GateTiming do
  @moduledoc "Measured gate overhead. Budgets are advice; exit status and timeouts determine correctness."

  defstruct duration_ms: 0, test_duration_ms: 0, slowest_stage: nil, warnings: []

  @type t :: %__MODULE__{
          duration_ms: non_neg_integer(),
          test_duration_ms: non_neg_integer(),
          slowest_stage: map() | nil,
          warnings: [String.t()]
        }

  @spec summarize([map()], non_neg_integer()) :: t()
  def summarize(stages, elapsed_ms) do
    duration = max(elapsed_ms, Enum.sum(Enum.map(stages, &duration/1)))
    tests = stages |> Enum.map(&test_duration/1) |> Enum.sum()

    slowest =
      stages
      |> Enum.map(&Map.get(&1, :slowest_stage, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.max_by(&duration/1, fn -> nil end)

    slowest =
      if slowest, do: %{name: Map.get(slowest, :name, "gate"), duration_ms: duration(slowest)}

    timing = %__MODULE__{duration_ms: duration, test_duration_ms: tests, slowest_stage: slowest}

    warnings =
      warning(tests >= 10_000, "test suite", tests, 10_000, timing) ++
        warning(duration >= 60_000, "complete check", duration, 60_000, timing)

    %{timing | warnings: warnings}
  end

  @spec combine([t() | nil]) :: t()
  def combine(timings), do: summarize(Enum.reject(timings, &is_nil/1), 0)

  defp test_duration(%{test_duration_ms: duration}), do: duration
  defp test_duration(stage), do: if(test_stage?(stage), do: duration(stage), else: 0)

  @spec text(t()) :: String.t()
  def text(timing) do
    slowest =
      case timing.slowest_stage do
        nil -> "unavailable"
        %{name: name, duration_ms: ms} -> "#{name} #{ms} ms"
      end

    "duration #{timing.duration_ms} ms; tests #{timing.test_duration_ms} ms; slowest stage: #{slowest}"
  end

  defp duration(stage), do: Map.get(stage, :duration_ms, 0) || 0

  defp test_stage?(stage) do
    argv = Map.get(stage, :argv, [])

    Regex.match?(~r/(?:^|[-_\/])(tests?|acceptance|e2e)(?:$|[-_\/])/, Map.get(stage, :name, "")) or
      Enum.any?(argv, &(&1 in ["test", "pytest", "pytest3", "rspec", "jest", "vitest"]))
  end

  defp warning(false, _label, _ms, _budget, _timing), do: []

  defp warning(true, label, ms, budget, timing),
    do: [
      "Time budget warning: #{label} took #{ms} ms (#{budget} ms advisory budget); #{text(timing)}. Correctness is unchanged."
    ]
end

defmodule Kogen.Contracts.GateTiming.Codec do
  @moduledoc false
  alias Kogen.Contracts.GateTiming

  def decode(nil), do: nil
  def decode(:null), do: nil
  def decode(%GateTiming{} = timing), do: timing

  def decode(record) when is_map(record) do
    slowest = Map.get(record, "slowest_stage")

    %GateTiming{
      duration_ms: Map.get(record, "duration_ms", 0),
      test_duration_ms: Map.get(record, "test_duration_ms", 0),
      warnings: Map.get(record, "warnings", []),
      slowest_stage:
        if(is_map(slowest),
          do: %{name: Map.get(slowest, "name"), duration_ms: Map.get(slowest, "duration_ms", 0)}
        )
    }
  end

  def latest(events) do
    reversed = Enum.reverse(events)

    Enum.find_value(reversed, fn event -> decode(Map.get(event, :timing)) end) ||
      Enum.find_value(reversed, &event_timing/1)
  end

  def event_timing(%{timing: timing}) when is_map(timing), do: decode(timing)
  def event_timing(%{gate_summary: gate}) when is_map(gate), do: decode(Map.get(gate, "timing"))
  def event_timing(_event), do: nil
end
