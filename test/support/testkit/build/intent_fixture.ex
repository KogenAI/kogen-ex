defmodule Kogen.E2e.Build.IntentFixture do
  @moduledoc "The default approved Intent and acceptance test of the tiny e2e Build project."

  @spec intent() :: String.t()
  def intent do
    """
    ---
    title: "Expose a ready value"
    domains: [kernel]
    size: small
    ---
    Make TinyApp.value/0 return the approved ready value.

    ## Acceptance
    - A1: TinyApp.value/0 returns :ready.

    ## Verify
    - A1: test

    ## Notes
    Keep the implementation inside lib/tiny_app.ex.
    #{request_section()}
    """
  end

  @spec acceptance() :: String.t()
  def acceptance do
    """
    defmodule TinyApp.AcceptanceTest do
      use ExUnit.Case, async: true

      @tag intent: "build-engine/A1"
      test "returns the ready value" do
        assert TinyApp.value() == :ready
      end
    end
    """
  end

  defp request_section,
    do: "\n## Request\nPreserve this fixture wording verbatim as source context."
end
