defmodule Kogen.E2e.ApprovalGatePathsTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Environment
  alias Kogen.Kernel.Approval
  alias Kogen.Testkit.Git
  alias Kogen.Workspace

  @moduletag :e2e
  @moduletag timeout: 300_000
  @slug "build-engine"
  @intent ".kogen/intents/#{@slug}/intent.md"

  setup %{tmp_dir: tmp_dir} do
    parent = Path.join(tmp_dir, "gate")

    seed =
      Build.prepare_seed!(parent,
        project_config: project_config(),
        extra_files: %{
          "ci/check.sh" => "#!/bin/sh\ntrue\n",
          ".credo.exs" => "%{}\n"
        }
      )

    {:ok, seed: seed, origin: Path.join(parent, "approved-origin.git")}
  end

  test "approval protects the gate definition, its config and the files its commands run",
       context do
    assert {:ok, preview} = prepare(context.seed, context.origin)
    manifest = preview.approval.protected_manifest

    assert manifest[".kogen/project.yaml"] == sha256(File.read!(project_yaml(context.seed)))
    assert manifest[".credo.exs"] == sha256("%{}\n")
    assert manifest["ci/check.sh"] == sha256("#!/bin/sh\ntrue\n")
    assert manifest["mix.exs"] == sha256(File.read!(Path.join(context.seed, "mix.exs")))
    assert manifest[".dialyzer_ignore.exs"] == Workspace.absent_digest()
    refute Map.has_key?(manifest, "ci/other.sh")
  end

  test "an Intent that declares changes_gate leaves the gate files editable", context do
    declare_changes_gate!(context.seed)

    assert {:ok, preview} = prepare(context.seed, context.origin)
    manifest = preview.approval.protected_manifest

    refute Map.has_key?(manifest, ".kogen/project.yaml")
    refute Map.has_key?(manifest, ".credo.exs")
    refute Map.has_key?(manifest, "ci/check.sh")
    refute Map.has_key?(manifest, ".dialyzer_ignore.exs")
    assert Map.has_key?(manifest, "mix.exs")
  end

  defp declare_changes_gate!(seed) do
    path = Path.join(seed, @intent)

    File.write!(
      path,
      String.replace(File.read!(path), "size: small\n", "size: small\nchanges_gate: true\n")
    )

    Git.git!(seed, ["add", "--all"])
    Git.git!(seed, ["commit", "--quiet", "-m", "Declare a gate change"])
    Git.git!(seed, ["push", "--quiet", "origin", "main"])
  end

  defp prepare(project, origin) do
    home = Path.join(Path.dirname(project), "approval-home")
    runtime = Environment.runtime!(project, home)
    {:ok, config} = Kogen.Project.load(project)
    {:ok, env} = Kogen.Kernel.candidate_environment(project, runtime, config)

    Approval.prepare(@slug, project, origin, "main", "Kogen Test", Map.merge(env, Git.env()))
  end

  defp project_yaml(seed), do: Path.join(seed, ".kogen/project.yaml")

  defp project_config do
    """
    name: tiny_app
    checks:
      - name: source-present
        argv: [sh, ci/check.sh]
        timeout_ms: 60000
    fix: []
    protected_paths:
      - mix.exs
    gate_paths:
      - .credo.exs
      - .dialyzer_ignore.exs
    domains:
      kernel: [lib]
    """
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
