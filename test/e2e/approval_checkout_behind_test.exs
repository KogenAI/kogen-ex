defmodule Kogen.E2e.ApprovalCheckoutBehindTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Environment
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Kernel.Approval
  alias Kogen.Kernel.CLI.ErrorOutput
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @tag timeout: 180_000
  @slug "build-engine"
  @guard "tools/guard.txt"

  setup %{tmp_dir: tmp_dir} do
    parent = Path.join(tmp_dir, "behind")

    seed =
      Build.prepare_seed!(parent,
        project_config: project_config(),
        extra_files: %{@guard => "version one\n"}
      )

    stale = Path.join(parent, "stale-checkout")
    Git.copy_tree!(seed, stale)
    advance_base!(seed)

    {:ok,
     parent: parent, seed: seed, stale: stale, origin: Path.join(parent, "approved-origin.git")}
  end

  test "approval from a stale checkout is refused and names the differing paths", context do
    assert {:error, {:checkout_behind_base, "main", [@guard]} = reason} =
             prepare(context.stale, context.origin)

    assert {3, message} = ErrorOutput.format(reason)

    assert message ==
             "environment/checkout_behind_base: checkout is behind main: #{@guard} differ; " <>
               "update your checkout first\n"
  end

  test "approval from a current checkout records the base bytes", context do
    assert {:ok, preview} = prepare(context.seed, context.origin)

    assert preview.approval.protected_manifest[@guard] == sha256("version two\n")

    assert preview.approval.base_sha ==
             context.origin |> Git.git!(["rev-parse", "main"]) |> String.trim()
  end

  test "a moved base lands once the checkout is updated", context do
    Git.git!(context.stale, ["pull", "--quiet", "--ff-only", "origin", "main"])

    assert {:ok, preview} = prepare(context.stale, context.origin)
    assert preview.approval.protected_manifest[@guard] == sha256("version two\n")
    assert {:ok, _approval_commit} = Kogen.Kernel.approve(preview)

    result =
      Build.run!(Path.join(context.parent, "build"), script(), %Options{
        seed_project: context.seed
      })

    assert result.build.status == :landed
    refute Enum.any?(result.events, &(&1.event == "protected_restored"))
  end

  defp prepare(project, origin) do
    home = Path.join(Path.dirname(project), "approval-home")
    runtime = Environment.runtime!(project, home)
    {:ok, config} = Kogen.Project.load(project)
    {:ok, env} = Kogen.Kernel.candidate_environment(project, runtime, config)

    Approval.prepare(@slug, project, origin, "main", "Kogen Test", Map.merge(env, Git.env()))
  end

  defp advance_base!(seed) do
    File.write!(Path.join(seed, @guard), "version two\n")
    Git.git!(seed, ["add", "--all"])
    Git.git!(seed, ["commit", "--quiet", "-m", "Change a protected file on the base"])
    Git.git!(seed, ["push", "--quiet", "origin", "main"])
  end

  defp project_config do
    """
    name: tiny_app
    checks:
      - name: source-present
        argv: [test, -s, lib/tiny_app.ex]
        timeout_ms: 60000
    fix: []
    protected_paths:
      - tools/**
    domains:
      kernel: [lib]
    """
  end

  defp script do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(
        :develop,
        "lib/tiny_app.ex",
        "defmodule TinyApp do\n  # revision: candidate\n  def value, do: :ready\nend\n"
      ),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
