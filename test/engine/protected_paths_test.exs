defmodule Kogen.Engine.ProtectedPathsTest do
  use Kogen.Testkit.Case

  alias Kogen.Engine.Build.ProtectedPaths
  alias Kogen.Engine.Build.Session
  alias Kogen.State.Approval
  alias Kogen.Testkit.Git

  @path "checks.yml"
  @base_bytes "check: base\n"

  setup %{tmp_dir: tmp_dir} do
    origin = Git.create!(tmp_dir)
    File.write!(Path.join(origin, @path), @base_bytes)
    Git.git!(origin, ["add", @path])
    Git.git!(origin, ["commit", "--quiet", "-m", "protect checks"])
    base_sha = origin |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()

    workdir = Path.join(tmp_dir, "candidate")
    Git.copy_tree!(origin, workdir)
    File.write!(Path.join(workdir, @path), "check: edited\n")

    {:ok, origin: origin, base_sha: base_sha, workdir: workdir}
  end

  test "restores the base bytes when the manifest agrees with the base tree", context do
    session = session(context, sha256(@base_bytes))

    assert {:ok, [@path]} = ProtectedPaths.restore(session)
    assert File.read!(Path.join(context.workdir, @path)) == @base_bytes
  end

  test "never writes base bytes that differ from the approved manifest", context do
    session = session(context, sha256("check: stale checkout\n"))

    assert {:error, {@path, {:controller_bug, reason}}} = ProtectedPaths.restore(session)
    assert reason =~ "approved bytes of #{@path} differ from the base tree"
    assert File.read!(Path.join(context.workdir, @path)) == "check: edited\n"
  end

  defp session(context, approved_sha) do
    keys = Session.__struct__() |> Map.from_struct() |> Map.keys()
    blank = Map.new(keys, &{&1, nil})

    struct!(
      Session,
      Map.merge(blank, %{
        request: %{origin: context.origin},
        approval: %Approval{
          slug: "guard-fixture",
          intent_bytes: "",
          intent_sha256: "",
          target_branch: "main",
          base_sha: context.base_sha,
          domains: [],
          acceptance_files: %{},
          protected_manifest: %{@path => approved_sha},
          by: "test",
          at: ~U[2026-10-05 00:00:00Z]
        },
        base_sha: context.base_sha,
        workdir: context.workdir,
        git_env: Git.env()
      })
    )
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
