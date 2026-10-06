defmodule Kogen.Harness.MutationAdvice do
  @moduledoc false
  alias Kogen.Contracts.ExchangeRequest, as: ExchangeRequest
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Exchange

  @spec deliver(struct(), struct(), struct()) :: struct()
  def deliver(opts, gate, state) do
    survivors =
      for command <- gate.checks,
          finding <- Map.get(command, :findings, []),
          finding.tool == "mutation" and finding.rule == "survived",
          do: finding.message

    if survivors == [] do
      state
    else
      items =
        state.items ++
          [Codec.user_item("Advisory mutation qualification: " <> Enum.join(survivors, "\n"))]

      send_advice(opts, state, items)
    end
  end

  defp send_advice(opts, state, items) when state.turns >= opts.limits.max_turns,
    do: %{state | items: items}

  defp send_advice(opts, state, items) do
    {model, effort} = opts.models.builder

    request = %ExchangeRequest{
      stage: :develop,
      turn: state.turns + 1,
      model: model,
      effort: effort,
      instructions:
        "Review these survivors and explain a test repair or explicit equivalence evidence. This is advisory; no score threshold.",
      items: items,
      tool_names: [],
      remaining_ms: min(max(state.deadline - System.monotonic_time(:millisecond), 0), 5_000)
    }

    tags = Map.put(opts.request_tags, :cache_epoch, "mutation-advice")

    case Exchange.respond(%{opts | request_tags: tags}, request) do
      {:ok, response} ->
        %{
          state
          | items: items ++ response.raw_items,
            usage: Codec.usage(state.usage, response.usage),
            turns: state.turns + 1
        }

      _ ->
        %{state | items: items}
    end
  end
end
