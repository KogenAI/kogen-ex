defmodule Kogen.Harness.StylerEvidenceTest do
  use Kogen.Testkit.Case

  alias Kogen.Testkit.Proc

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "docs/audits/styler/evidence.exs")
  @external_resource @script

  test "the local audit retains real two-pass results and executable correctness counterexamples",
       %{tmp_dir: output} do
    assert {text, 0} =
             Proc.cmd("mise", ["exec", "--", "mix", "run", "--no-compile", @script, output],
               cd: @root,
               env: [{"MIX_ENV", "test"}, {"ERL_FLAGS", "+S 2:2"}]
             )

    assert text =~ "real inputs"
    assert text =~ "strict-boolean-case: correctness counterexample"
    report = output |> Path.join("report.json") |> File.read!() |> Jason.decode!()
    assert report["elixir"] == "1.20.4"
    assert report["styler"] == "1.12.2"
    assert report["file_count"] > 500
    assert report["file_count"] == report["unchanged"]
    assert report["file_count"] == report["idempotent"]
    assert report["file_count"] == report["parseable"]
    assert report["failures"] == []
    examples = Map.new(report["reproductions"], &{&1["name"], &1})

    for name <-
          ~w(large-number map-construction with-success-and-error with-binding-order datetime-microsecond datetime-piped-microsecond) do
      assert examples[name]["behavior_preserved"]
      assert examples[name]["idempotent"]
    end

    for name <- ~w(strict-boolean-case with-strict-true duplicate-config-order) do
      assert examples[name]["classification"] == "correctness counterexample"
      refute examples[name]["behavior_preserved"]
      assert examples[name]["idempotent"]
      refute examples[name]["before"] == examples[name]["after"]
    end
  end
end
