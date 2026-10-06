defmodule Kogen.Harness.DialyzerSummaryTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Gate
  alias Kogen.Harness.Opts

  test "done-gate summary separates changed files and prioritizes three warnings with complete evidence",
       %{tmp_dir: root} do
    output =
      "Total errors: 6, Skipped: 0, Unnecessary Skips: 0\n" <>
        Enum.map_join(
          [
            {"lib/a.ex", 1},
            {"lib/b.ex", 2},
            {"lib/changed.ex", 20},
            {"lib/c.ex", 3},
            {"lib/changed.ex", 30},
            {"lib/d.ex", 4}
          ],
          "\n",
          &warning/1
        )

    {_opts, gate} = run_gate(root, output, fn -> {:ok, ["lib/changed.ex"]} end)
    assert gate.status == :fail

    assert %{changed: 2, unchanged: 4, unavailable_locations: 0, unknown_scope: 0} =
             gate.dialyzer_summary

    text = Enum.join(gate.failures, "\n")
    assert text =~ "2 in changed files, 4 in unchanged files, 0 with unavailable locations"
    assert text =~ "may be downstream effects"
    assert length(Regex.scan(~r/\[dialyzer\/pattern_match\]/, text)) == 3
    assert text =~ "lib/changed.ex:20: error: [dialyzer/pattern_match]"
    assert text =~ "lib/changed.ex:30: error: [dialyzer/pattern_match]"
    assert text =~ "lib/a.ex:1: error: [dialyzer/pattern_match]"
    refute text =~ "lib/d.ex:4"
    assert text =~ "complete findings: #{gate.findings_path}"
    assert text |> String.split("\n") |> List.last() =~ "gate:"
    assert length(Jason.decode!(File.read!(gate.findings_path))["findings"]) == 6
    assert File.read!(hd(gate.checks).log_path) == output
    {:ok, json} = Codec.encode_json_value(gate)

    assert %{"changed" => 2, "unchanged" => 4, "first" => first} =
             Jason.decode!(json)["dialyzer_summary"]

    assert length(first) == 3
  end

  test "missing diagnostic locations are counted from the complete tool total", %{tmp_dir: root} do
    output =
      "Total errors: 5, Skipped: 0, Unnecessary Skips: 0\n" <>
        warning({"lib/origin.ex", 10}) <> warning({"lib/downstream.ex", 15})

    {_opts, gate} = run_gate(root, output, fn -> {:ok, ["lib/origin.ex"]} end)
    assert %{changed: 1, unchanged: 1, unavailable_locations: 3} = gate.dialyzer_summary
    assert Enum.join(gate.failures) =~ "3 with unavailable locations"
    assert length(gate.dialyzer_summary.first) == 2
  end

  test "aggregate-only output identifies unavailable details without inventing a source", %{
    tmp_dir: root
  } do
    {_opts, gate} =
      run_gate(root, "Total errors: 3, Skipped: 0, Unnecessary Skips: 0\n", fn -> {:ok, []} end)

    assert %{changed: 0, unchanged: 0, unavailable_locations: 3, first: []} =
             gate.dialyzer_summary

    assert Enum.join(gate.failures) =~ "Warning details unavailable"
    report = Jason.decode!(File.read!(gate.findings_path))
    assert [%{"path" => nil, "line" => nil, "col" => nil}] = report["findings"]
  end

  test "unavailable change scope does not turn known locations into unchanged code", %{
    tmp_dir: root
  } do
    output =
      "Total errors: 1, Skipped: 0, Unnecessary Skips: 0\n" <> warning({"lib/origin.ex", 10})

    {_opts, gate} = run_gate(root, output, fn -> {:error, :unavailable} end)

    assert %{changed: 0, unchanged: 0, unavailable_locations: 0, unknown_scope: 1} =
             gate.dialyzer_summary

    assert Enum.join(gate.failures) =~ "1 with change scope unavailable"
    assert Enum.join(gate.failures) =~ "lib/origin.ex:10: error:"
  end

  defp warning({path, line}),
    do:
      "#{path}:#{line}:pattern_match\nReturn shape cannot match at warning #{line}.\n________________________________________________________________________________\n"

  defp run_gate(root, output, changed_paths) do
    workdir = Path.join(root, "project")
    File.mkdir_p!(workdir)
    File.write!(Path.join(workdir, "diagnostics.log"), output)

    spec = %CheckSpec{
      name: "dialyzer",
      argv: ["/bin/sh", "-c", "/bin/cat diagnostics.log; exit 2"],
      timeout_ms: 30_000
    }

    project = %Project{
      root: workdir,
      name: "fixture",
      checks: [spec],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{}
    }

    opts = %Opts{
      workdir: workdir,
      run_dir: Path.join(root, "run"),
      project: project,
      provider_mod: nil,
      provider_config: nil,
      proc_mod: Kogen.Proc,
      changed_paths: changed_paths
    }

    assert {:ok, gate} = Gate.run(opts, System.monotonic_time(:millisecond) + 30_000)
    {opts, gate}
  end
end
