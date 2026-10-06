defmodule Kogen.Resilience.Recovery do
  @moduledoc "Continues an interrupted turn from the received conversation."
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError

  @instruction %{
    "role" => "user",
    "content" => [
      %{
        "type" => "input_text",
        "text" =>
          "The response stream was interrupted. Continue the same turn from the received progress above. Preserve its findings and constraints; do not restart the task or repeat completed work. Proposed tool calls above were not executed; reissue any still needed."
      }
    ]
  }

  def continue(request, %ProviderError{class: class, partial_items: [_ | _] = items})
      when class in [:timeout, :stall, :transport, :malformed] do
    added = items ++ [@instruction]

    %{
      request
      | input: request.input ++ added,
        previous_response_id: nil,
        continuation_items: request.continuation_items ++ added
    }
  end

  def continue(request, _error), do: request

  def complete(request, {:ok, %ModelResponse{} = response}) do
    text = request.continuation_items |> Enum.flat_map(&assistant_text/1) |> Enum.join("")

    {:ok,
     %{
       response
       | text: text <> response.text,
         raw_items: request.continuation_items ++ response.raw_items
     }}
  end

  def complete(_request, error), do: error

  defp assistant_text(%{"role" => "assistant", "content" => content}),
    do: for(%{"type" => "output_text", "text" => text} <- content, do: text)

  defp assistant_text(_item), do: []
end
