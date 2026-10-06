defmodule Kogen.Queue.Selection do
  @moduledoc "Dependency eligibility and caller priority, recomputed before each Build."

  alias Kogen.Queue.IntentStatus

  @spec prepare([IntentStatus.t()], [String.t()]) :: [IntentStatus.t()]
  def prepare(statuses, delivered \\ []) do
    delivered =
      MapSet.new(delivered ++ for(item <- statuses, item.status == :landed, do: item.slug))

    known = Map.new(statuses, &{&1.slug, &1})

    Enum.map(statuses, fn item ->
      if item.status in [:approved, :blocked] do
        case blocked_reason(item, known, delivered) do
          nil -> %{item | status: :approved, detail: nil}
          reason -> %{item | status: :blocked, detail: reason}
        end
      else
        item
      end
    end)
  end

  @spec reason(IntentStatus.t()) :: String.t()
  def reason(item) do
    deps = if item.blocks_on == [], do: "no dependencies", else: "dependencies delivered"
    "priority #{item.priority}; #{deps}; ties by approval time and slug"
  end

  defp blocked_reason(%{scheduling_error: error}, _known, _delivered) when is_binary(error),
    do: "invalid scheduling metadata: #{error}"

  defp blocked_reason(item, known, delivered) do
    invalid = Enum.reject(item.blocks_on, &valid_slug?/1)

    unknown =
      Enum.reject(item.blocks_on, &(Map.has_key?(known, &1) or MapSet.member?(delivered, &1)))

    cycle = cycle(item.slug, item.slug, known, delivered, [])
    missing = Enum.reject(item.blocks_on, &MapSet.member?(delivered, &1))

    cond do
      invalid != [] -> "invalid dependencies: #{Enum.join(invalid, ", ")}"
      unknown != [] -> "unknown dependencies: #{Enum.join(unknown, ", ")}"
      cycle -> "dependency cycle: #{Enum.join(cycle, " -> ")}"
      missing != [] -> "waiting for delivered dependencies: #{Enum.join(missing, ", ")}"
      true -> nil
    end
  end

  defp cycle(current, target, known, delivered, path) do
    item = Map.get(known, current)

    if item && current not in path && not MapSet.member?(delivered, current) do
      Enum.find_value(item.blocks_on, fn dep ->
        if dep == target,
          do: Enum.reverse([target, current | path]),
          else: cycle(dep, target, known, delivered, [current | path])
      end)
    end
  end

  defp valid_slug?(slug), do: Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)
end
