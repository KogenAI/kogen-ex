defmodule Kogen.Harness.GateFindingsReportTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project
  alias Kogen.Harness.Gate
  alias Kogen.Harness.Opts

  test "done gate preserves every diagnostic from a report larger than its output tail", %{
    tmp_dir: root
  } do
    output =
      Enum.map_join(
        1..200,
        "\n",
        &"lib/sample.ex:#{&1}:pattern_match\nReturn shape cannot match; correct the decoder.\n________________________________________________________________________________"
      )

    File.mkdir_p!(Path.join(root, "project"))
    source = Path.join([root, "project", "diagnostics.log"])
    File.write!(source, output)

    spec = %CheckSpec{
      name: "dialyzer",
      argv: ["/bin/sh", "-c", "/bin/cat diagnostics.log; exit 1"],
      timeout_ms: 30_000
    }

    opts = options(root, spec)
    assert {:ok, gate} = Gate.run(opts, System.monotonic_time(:millisecond) + 30_000)
    assert gate.status == :fail
    assert is_binary(gate.findings_path)
    report = gate.findings_path |> File.read!() |> Jason.decode!()
    findings = Enum.filter(report["findings"], &(&1["tool"] == "dialyzer"))
    assert length(findings) == 200
    assert hd(findings)["line"] == 1
    assert List.last(findings)["line"] == 200
    assert Enum.all?(findings, &is_nil(&1["col"]))
    assert Enum.all?(findings, &is_binary(&1["id"]))
    assert hd(findings)["explanation"] =~ "correct the decoder"
  end

  defp options(root, spec) do
    project = %Project{
      root: root,
      name: "fixture",
      checks: [spec],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{}
    }

    %Opts{
      workdir: Path.join(root, "project"),
      run_dir: Path.join(root, "run"),
      project: project,
      provider_mod: Kogen.Provider.Fake,
      provider_config: nil,
      proc_mod: Kogen.Proc
    }
  end
end
