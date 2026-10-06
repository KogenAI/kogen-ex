defmodule Kogen.Harness.Continuation do
  @moduledoc false
  alias Kogen.Conversation
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request
  alias Kogen.Harness.Recording
  alias Kogen.Tooling.Error

  def prepare(opts, state, remaining_ms) do
    limit = Map.get(opts.project.build || %{}, :context_bytes)

    if Conversation.due?(state.items, limit) do
      summarize(opts, state, remaining_ms, limit)
    else
      {:ok, state}
    end
  end

  defp summarize(opts, state, remaining_ms, limit) do
    {model, effort} = opts.models.builder

    path =
      Path.join(
        opts.run_dir,
        "continuation-#{state.turns}-#{System.unique_integer([:positive, :monotonic])}.md"
      )

    request = %Request{
      stage: :develop,
      turn: state.turns,
      model: model,
      effort: effort,
      instructions: Conversation.instructions(),
      items: state.items,
      tool_names: [],
      remaining_ms: remaining_ms
    }

    tags = Map.put(opts.request_tags, :cache_epoch, "checkpoint-#{state.turns}")

    with {:ok, response} <- Exchange.respond(%{opts | request_tags: tags}, request),
         {:ok, items, metrics} <-
           Conversation.checkpoint(response, state.authority, state.items, limit, path),
         :ok <- record(opts, state, path, metrics) do
      {:ok,
       %{
         state
         | items: items,
           cache_epoch: Conversation.cache_epoch(items),
           usage: Codec.usage(state.usage, response.usage)
       }}
    else
      {:error, reason} -> {:error, %Error{reason: :continuation_failed, detail: inspect(reason)}}
    end
  end

  defp record(opts, state, path, metrics) do
    event = %{
      event: :context_continued,
      stage: :develop,
      turn: state.turns,
      path: path,
      metrics: metrics,
      detail: "Continuing the same approved Build from a context checkpoint."
    }

    with :ok <- Recording.append(opts, event.event, event.stage, event.turn, event) do
      if opts.event_recorder, do: opts.event_recorder.(event), else: :ok
    end
  end
end
