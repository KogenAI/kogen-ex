defmodule Kogen.Contracts.CommandExit do
  @moduledoc "Shared classification for command statuses that mean a tool is unavailable."

  @missing_tool_statuses [126, 127]

  @spec tool_missing?(integer() | nil) :: boolean()
  def tool_missing?(status), do: status in @missing_tool_statuses
end
