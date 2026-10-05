defmodule Kogen.Kernel.ShapeErrorOutputTest do
  use ExUnit.Case, async: true

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProviderError
  alias Kogen.Kernel.CLI.ErrorOutput

  test "a retried-out provider error says shaping stopped and no Intent was written" do
    error = %ProviderError{class: :timeout, message: "ChatGPT request timed out."}

    assert {4, text} = ErrorOutput.format_shape(error)
    assert text =~ "provider/timeout: ChatGPT request timed out.\n"
    assert text =~ "shape/provider_failed: shaping stopped on a provider error after its retries"
    assert text =~ "no Intent was written"
  end

  test "a provider failure wrapped in a Failure is reported the same way" do
    failure = %Failure{class: :provider, reason: :overload, detail: "overloaded"}

    assert {4, text} = ErrorOutput.format_shape(failure)
    assert text =~ "provider/overload: overloaded"
    assert text =~ "shape/provider_failed"
  end

  test "login and usage-limit errors say retrying cannot fix them" do
    error = %ProviderError{class: :usage_limit, message: "usage limit reached"}

    assert {4, text} = ErrorOutput.format_shape(error)
    assert text =~ "that retrying cannot fix"
  end

  test "other shaping failures keep their usual output" do
    assert ErrorOutput.format_shape(:intent_not_found) == ErrorOutput.format(:intent_not_found)
  end

  test "lint errors print a line only when one is known" do
    issues = [
      %{rule: :missing_verify, line: nil, message: "Add Verify."},
      %{rule: :invalid_verify, line: 12, message: "Unknown Verify."}
    ]

    assert {1, text} = ErrorOutput.format({:lint, issues})
    assert text =~ "  missing_verify: Add Verify.\n"
    assert text =~ "  invalid_verify at line 12: Unknown Verify.\n"
    refute text =~ "at line :"
  end
end
