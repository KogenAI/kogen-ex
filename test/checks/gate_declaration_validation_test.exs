defmodule Kogen.Checks.GateDeclarationValidationTest do
  use ExUnit.Case, async: true

  alias Kogen.Checks
  alias Kogen.Checks.ShapeValidation
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Project

  test "acceptance source naming a gate file requires changes_gate" do
    intent = %Intent{
      slug: "gate-validation",
      title: "Change the project gate",
      size: :small,
      brief: "Change Tiny while preserving its public function.",
      acceptance: [],
      domains: ["app"],
      notes: "Approach: Change Tiny.value/0 and preserve its public result and function path.",
      path: ".kogen/intents/gate-validation/intent.md",
      sha256: "hash",
      changes_gate: false
    }

    request = %ShapeValidation{
      workdir: "/tmp/gate-validation",
      project: project(),
      intent: intent,
      acceptance_bytes: ~s{File.write!(".credo.exs", "changed\n")},
      run_dir: "/tmp/gate-validation-run",
      env: %{},
      git_env: %{}
    }

    assert {:error,
            %Failure{
              class: :candidate,
              reason: :undeclared_gate_path,
              detail: detail
            }} = Checks.validate_shape(request)

    assert detail =~ ".credo.exs"
    assert detail =~ "changes_gate: true"
  end

  defp project do
    %Project{
      root: "/tmp/gate-validation",
      name: "gate-validation",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      gate_paths: [".credo.exs"],
      domains: %{},
      env: %{}
    }
  end
end
