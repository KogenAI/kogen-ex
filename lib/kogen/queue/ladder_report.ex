defmodule Kogen.Queue.LadderReport do
  @moduledoc false

  alias Kogen.State.Event

  @doc "The report sections of a ladder Build, in order."
  @spec sections([Event.t()]) :: [{String.t(), term()}]
  def sections(events) do
    [
      {"rungs", rungs(events)},
      {"parallel", parallel(events)},
      {"edge_probe", edge_probe(events)},
      {"acceptance_demoted", demotions(events)},
      {"best_candidate", best_candidate(events)}
    ]
  end

  # Ladder Builds: each rung's time and cost, the parallel pick, demoted acceptance items,
  # and the best Candidate pushed for a human when no rung was green.
  defp rungs(events) do
    for %Event{event: "rung_finished"} = event <- events do
      json_object([
        {"attempt", event.attempt},
        {"rung", event.rung},
        {"experimental", event.experimental == true},
        {"model", event.model},
        {"effort", event.effort},
        {"result", event.result},
        {"reason", nullable(reason_text(event.reason))},
        {"wall_ms", event.wall_ms},
        {"tokens", event.tokens || %{}}
      ])
    end
  end

  defp parallel(events) do
    case Enum.find(events, &(&1.event == "parallel_selected")) do
      %Event{} = event ->
        json_object([
          {"selected", event.attempt},
          {"result", event.result},
          {"outcomes", event.outcomes || []},
          {"cross_check", cross_check(events)}
        ])

      nil ->
        :null
    end
  end

  defp cross_check(events) do
    case Enum.find(events, &(&1.event == "cross_check")) do
      %Event{} = event ->
        json_object([
          {"status", event.status},
          {"reason", nullable(reason_text(event.reason))},
          {"wall_ms", event.wall_ms},
          {"matrix", event.matrix || []}
        ])

      nil ->
        :null
    end
  end

  # The ladder's edge probe: tests generated and kept, and each green Candidate's passes.
  defp edge_probe(events) do
    case Enum.find(events, &(&1.event == "edge_probe")) do
      %Event{} = event ->
        json_object([
          {"status", event.status},
          {"reason", nullable(reason_text(event.reason))},
          {"generated", event.generated || 0},
          {"kept", event.kept || 0},
          {"selected", nullable(event.attempt)},
          {"wall_ms", event.wall_ms},
          {"candidates", event.matrix || []},
          {"repair", nullable(event.repair)}
        ])

      nil ->
        :null
    end
  end

  defp demotions(events) do
    for %Event{event: "acceptance_demoted"} = event <- events do
      json_object([
        {"item", event.item},
        {"verdict", event.verdict},
        {"reason", nullable(event.reason)},
        {"attempt", nullable(event.attempt)}
      ])
    end
  end

  defp best_candidate(events) do
    case Enum.find(Enum.reverse(events), &(&1.event == "best_candidate")) do
      %Event{} = event ->
        json_object([
          {"attempt", event.attempt},
          {"branch", event.branch},
          {"commit", event.commit},
          {"reason", nullable(reason_text(event.reason))},
          {"metrics", event.metrics || %{}},
          {"failing", event.failing || %{}},
          {"findings", event.findings || []}
        ])

      nil ->
        :null
    end
  end

  defp reason_text(nil), do: nil
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp json_object(pairs), do: Map.new(pairs)

  defp nullable(nil), do: :null
  defp nullable(value), do: value
end
