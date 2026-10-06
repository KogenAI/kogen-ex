defmodule Kogen.Runner.RailsEdgeTests do
  @moduledoc false

  @spec instructions(String.t()) :: String.t()
  def instructions(base) do
    base
    |> String.replace(
      "black-box ExUnit tests",
      "black-box Ruby Minitest tests requiring test_helper"
    )
    |> String.replace(
      "one test module named KogenEdge.<a short name>Test",
      "one test class named KogenEdgeTest inheriting ActiveSupport::TestCase"
    )
    |> String.replace("```elixir", "```ruby")
  end

  @spec parse(String.t()) :: {:ok, Kogen.Runner.EdgeTests.suite()} | {:error, atom()}
  def parse(text) do
    source =
      case Regex.run(~r/```ruby[ \t]*\n(.*?)```/s, text, capture: :all_but_first) do
        [source] -> source
        nil -> text
      end

    names =
      ~r/^\s*(?:test\s+"([^"\n]+)"|def\s+(test_\w+))/m
      |> Regex.scan(source, capture: :all_but_first)
      |> Enum.map(fn
        [name] -> "test_" <> String.replace(name, ~r/\s+/, "_")
        ["", method] -> method
      end)

    cond do
      not Regex.match?(~r/^\s*class\s+\w+Test\s*</m, source) -> {:error, :no_test_module}
      names == [] -> {:error, :no_tests}
      length(names) > 20 or length(Enum.uniq(names)) != length(names) -> {:error, :invalid_tests}
      true -> {:ok, %{source: source, names: names, generated: length(names)}}
    end
  end
end
