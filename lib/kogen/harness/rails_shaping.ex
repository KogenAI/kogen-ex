defmodule Kogen.Harness.RailsShaping do
  @moduledoc false

  @spec instructions(String.t()) :: String.t()
  def instructions(base) do
    base
    |> String.replace("_test.exs", "_test.rb")
    |> String.replace(
      "`@tag intent: \"<slug>/A<n>\"` test tag",
      "`test_A<n>_outcome` Minitest method name"
    )
    |> String.replace(
      "Use `async: true`, test through public functions, and add one `@tag intent: \"<slug>/A<n>\"` for every Acceptance item.",
      ~s{Use Minitest with `require "test_helper"`, test observable public behavior, and name each test `test_A<n>_outcome` (or Rails `test "A<n> outcome"`) for its Acceptance item.}
    )
    |> Kernel.<>(
      "\nThis is a Ruby on Rails project. Write Ruby Minitest acceptance tests under test/acceptance when staged. Kogen runs `bundle exec rails test {path}` and records each test's A<n> method name. Do not use ExUnit or Mix commands.\n"
    )
  end
end
