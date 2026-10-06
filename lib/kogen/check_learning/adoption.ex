defmodule Kogen.CheckLearning.Adoption do
  @moduledoc false
  alias Kogen.CheckLearning.Store

  @spec draft(Path.t(), struct(), map(), boolean()) :: {:ok, Path.t() | nil} | {:error, term()}
  def draft(_directory, _proposal, _result, false), do: {:ok, nil}

  def draft(directory, proposal, result, true) do
    path = Path.join(directory, "adoption-intent.md")

    text = """
    ---
    title: "Adopt check for recurring Build failure"
    domains: [checks]
    size: small
    changes_gate: true
    ---
    Add the qualified rule #{result.rule_sha256} to #{proposal.target}, with no dependency on the other check package.
    Observed failure: #{proposal.observed_failure}

    ## Acceptance
    - A1: The planted bad example reports the expected feedback and valid contrasting examples pass.
    - A2: The representative real-code sample preserves the recorded precision without unrelated findings.
    - A3: The protected rule is enabled only after this Intent receives its own caller approval.

    ## Verify
    - A1: test
    - A2: test
    - A3: test

    ## Notes
    Draft only. Caller must shape and approve this individual protected rule in #{proposal.target}.
    Evidence: qualification.json and proposal-evidence.json in #{directory}.
    Real-code precision: #{result.metrics.precision}; checker sample cost: #{result.measured_build_effect.checker_wall_ms} ms.
    Preserve these examples and Build-effect samples for later comparisons. Mining has enabled no blocking gate.
    """

    with :ok <- Store.write_text(path, text), do: {:ok, path}
  end
end
