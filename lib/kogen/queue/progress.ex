defmodule Kogen.Queue.Progress do
  @moduledoc "Acceptance evidence for the complete approved change, including unverified items."

  alias Kogen.State
  alias Kogen.State.Event

  @spec from_events([Event.t()]) :: map() | nil
  def from_events(events) do
    items = Enum.find_value(events, & &1.acceptance_items)

    if items && items != [] do
      expected = State.acceptance_items(items)
      rows = Enum.find_value(Enum.reverse(events), %{}, &evidence/1)
      verified = for {id, _status} <- expected, Map.get(rows, id) == "passed", do: id
      %{verified: verified, remaining: Enum.map(expected, &elem(&1, 0)) -- verified}
    end
  end

  defp evidence(%Event{event: "acceptance_result", ledger: rows}) when is_list(rows),
    do: State.acceptance_ledger(rows)

  defp evidence(%Event{acceptance_items: items}) when is_list(items),
    do: items |> State.acceptance_items() |> Map.new()

  defp evidence(_event), do: nil
end
