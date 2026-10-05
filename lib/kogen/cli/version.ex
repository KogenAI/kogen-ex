defmodule Kogen.Cli.Version do
  @moduledoc "Formats the build identity that mix.exs stores as `0.0.0+<sha8>.<yyyymmdd>[.dirty]`."

  @spec display(String.t()) :: String.t()
  def display(vsn) do
    case Regex.run(~r/\+([0-9a-f]+)\.(\d{4})(\d{2})(\d{2})(\.dirty)?\z/, vsn) do
      [_match, sha, year, month, day] ->
        "#{sha} (#{year}-#{month}-#{day})"

      [_match, sha, year, month, day, _dirty] ->
        "#{sha} (#{year}-#{month}-#{day}, uncommitted changes)"

      nil ->
        "unknown build (#{vsn})"
    end
  end
end
