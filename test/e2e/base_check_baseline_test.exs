defmodule Kogen.E2e.BaseCheckBaselineTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Workspace

  @moduletag :e2e
  @moduletag timeout: 300_000

  test "an unchanged base-red format finding is warned about and the Candidate lands", %{
    tmp_dir: tmp_dir
  } do
    seed = prepare_seed!(tmp_dir)

    script = [
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", ready_source()),
      ScriptedProvider.answer(:develop, "Done.")
    ]

    result =
      Build.run!(Path.join(tmp_dir, "build"), script, %Options{
        seed_project: seed,
        recipe: "direct"
      })

    assert %Result{build: %{status: :landed}, run_status: :landed} = result

    assert {:ok, approval} =
             Kogen.State.approval(
               result.fixture.origin,
               "build-engine",
               result.fixture.git_env
             )

    assert [%{name: "format", status: :red, findings: findings}] =
             Enum.filter(approval.check_baseline, &(&1.name == "format"))

    assert Enum.any?(findings, &(&1.path == "lib/old.ex" and &1.id == "unformatted"))
    assert {:ok, report} = Build.report(result)

    assert %{"status" => "pass", "warnings" => warnings} =
             report |> :json.decode() |> Map.fetch!("last_gate")

    assert Enum.any?(warnings, &String.contains?(&1, "format"))

    assert {:ok, landed} =
             Workspace.ref_read(result.fixture.origin, "refs/heads/main", result.fixture.git_env)

    assert landed == result.build.landed_sha
  end

  defp prepare_seed!(tmp_dir) do
    project_config = """
    name: tiny_app
    checks:
      - name: source-present
        argv: [test, -s, lib/tiny_app.ex]
        timeout_ms: 60000
      - name: format
        argv: [sh, tools/format-check.sh]
        timeout_ms: 60000
    fix: []
    domains:
      kernel: [lib, test]
    """

    Build.prepare_seed!(Path.join(tmp_dir, "seed"),
      project_config: project_config,
      extra_files: %{
        "lib/old.ex" => "defmodule Old do\n def value,do: :old\nend\n",
        "tools/format-check.sh" => format_check_script()
      }
    )
  end

  defp format_check_script do
    """
    #!/bin/sh
    printf '** (Mix) mix format failed due to --check-formatted.\\nThe following files are not formatted:\\n  lib/old.ex\\n'
    if [ -f lib/new.ex ]; then printf '  lib/new.ex\\n'; fi
    exit 1
    """
  end

  defp ready_source do
    "defmodule TinyApp do\n  # revision: base-check-baseline\n  def value, do: :ready\nend\n"
  end
end
