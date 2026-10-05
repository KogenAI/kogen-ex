defmodule Kogen.Shaper.GatePathValidationTest do
  use ExUnit.Case, async: true

  alias Kogen.Contracts.Project
  alias Kogen.Shaper.Validation

  test "an approach naming a gate path requires the boolean declaration" do
    assert {:error, failure} = Validation.intent(intent(false), "intent.md", project())
    assert failure.detail =~ "Makefile"
    assert failure.detail =~ "changes_gate: true"

    assert {:ok, parsed} = Validation.intent(intent(true), "intent.md", project())
    assert parsed.changes_gate
  end

  test "a request-context mention does not require the declaration" do
    source =
      false
      |> intent()
      |> String.replace("the `Makefile` check target", "the check target")
      |> Kernel.<>("\n## Request\nThe request mentions Makefile for context.\n")

    assert {:ok, parsed} = Validation.intent(source, "intent.md", project())
    refute parsed.changes_gate
  end

  defp project do
    %Project{
      root: "/tmp/gate-path-validation",
      name: "project",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      gate_paths: ["Makefile"],
      domains: %{"app" => ["lib"]}
    }
  end

  defp intent(changes_gate?) do
    flag = if changes_gate?, do: "changes_gate: true\n", else: ""

    """
    ---
    title: Update the project check
    domains: [app]
    size: small
    #{flag}---
    Update the project check target while preserving unrelated targets.

    ## Acceptance
    - A1: The project check target uses the requested command.

    ## Verify
    - A1: test domain=app

    ## Notes
    Approach: Update the `Makefile` check target through the project configuration and preserve unrelated targets.
    """
  end
end
