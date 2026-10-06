defmodule Kogen.Contracts.StreamProgress do
  @moduledoc "Received Responses output that can be carried into a replacement request."
  defstruct items: %{}, summaries: %{}

  def feed(progress, %{"type" => type, "output_index" => index, "item" => item})
      when type in ["response.output_item.added", "response.output_item.done"] and is_map(item) and
             is_integer(index) and index >= 0 do
    %{progress | items: Map.put(progress.items, index, item)}
  end

  def feed(progress, %{
        "type" => "response.output_text.delta",
        "output_index" => index,
        "content_index" => part,
        "delta" => delta
      })
      when is_integer(index) and index >= 0 and is_integer(part) and part in 0..1023 and
             is_binary(delta) do
    item = Map.get(progress.items, index, %{"type" => "message", "role" => "assistant"})

    content =
      case Map.get(item, "content", []) do
        content when is_list(content) -> content
        _invalid -> []
      end

    content =
      content ++
        List.duplicate(
          %{"type" => "output_text", "text" => ""},
          max(part + 1 - length(content), 0)
        )

    content =
      List.update_at(content, part, fn part ->
        Map.put(part, "text", append(Map.get(part, "text"), delta))
      end)

    %{progress | items: Map.put(progress.items, index, Map.put(item, "content", content))}
  end

  def feed(progress, %{
        "type" => "response.function_call_arguments.delta",
        "output_index" => index,
        "delta" => delta
      })
      when is_integer(index) and index >= 0 and is_binary(delta) do
    items =
      Map.update(
        progress.items,
        index,
        %{},
        &Map.put(&1, "arguments", append(Map.get(&1, "arguments"), delta))
      )

    %{progress | items: items}
  end

  def feed(progress, %{
        "type" => "response.reasoning_summary_text.delta",
        "output_index" => index,
        "summary_index" => part,
        "delta" => delta
      })
      when is_integer(index) and index >= 0 and is_integer(part) and part >= 0 and
             is_binary(delta) do
    summaries = Map.update(progress.summaries, {index, part}, delta, &(&1 <> delta))
    %{progress | summaries: summaries}
  end

  def feed(progress, _event), do: progress

  def items(progress) do
    output = progress.items |> Enum.sort() |> Enum.flat_map(fn {_index, item} -> replay(item) end)
    summaries = progress.summaries |> Enum.sort() |> Enum.map_join("\n", &elem(&1, 1))

    output ++
      if(summaries == "", do: [], else: [note("Received reasoning summary:\n" <> summaries)])
  end

  defp replay(%{"type" => "message", "content" => content} = item) when is_list(content) do
    content =
      for %{"type" => "output_text", "text" => text} = part <- content,
          is_binary(text) and text != "",
          do: part

    if content == [],
      do: [],
      else: [item |> Map.drop(["id", "status"]) |> Map.put("content", content)]
  end

  defp replay(%{"type" => "reasoning", "encrypted_content" => encrypted} = item)
       when is_binary(encrypted) and encrypted != "", do: [item]

  defp replay(%{"type" => "reasoning", "summary" => summary}) when is_list(summary) do
    text =
      summary
      |> Enum.flat_map(fn
        %{"text" => text} when is_binary(text) -> [text]
        _part -> []
      end)
      |> Enum.join("\n")

    if text == "", do: [], else: [note("Received reasoning summary:\n" <> text)]
  end

  defp replay(%{"type" => "function_call", "name" => name, "arguments" => arguments})
       when is_binary(name) and is_binary(arguments) do
    [
      note(
        "The interrupted response proposed this tool call. It was NOT executed. Reissue it if needed; its arguments may be incomplete:\n" <>
          name <> "\n" <> arguments
      )
    ]
  end

  defp replay(_item), do: []

  defp append(text, delta) when is_binary(text), do: text <> delta
  defp append(_text, delta), do: delta

  defp note(text),
    do: %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}
end
