defmodule Kogen.Workspace.ProtectedRestoreTest do
  use Kogen.Testkit.Case

  alias Kogen.Testkit.Git
  alias Kogen.Workspace

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
    approved = approved(context, sha256(@base_bytes))

    assert {:ok, [@path]} = Workspace.restore_protected(approved)
    assert File.read!(Path.join(context.workdir, @path)) == @base_bytes
  end

  test "never writes base bytes that differ from the approved manifest", context do
    approved = approved(context, sha256("check: stale checkout\n"))

    assert {:error, {@path, {:controller_bug, reason}}} = Workspace.restore_protected(approved)
    assert reason =~ "approved bytes of #{@path} differ from the base tree"
    assert File.read!(Path.join(context.workdir, @path)) == "check: edited\n"
  end

  test "removes a file the approval requires to stay absent", context do
    ignore = ".dialyzer_ignore.exs"
    File.write!(Path.join(context.workdir, ignore), "[]\n")
    approved = approved(context, %{ignore => Workspace.absent_digest()})

    assert {:ok, [^ignore]} = Workspace.restore_protected(approved)
    refute File.exists?(Path.join(context.workdir, ignore))
  end

  test "leaves an absent protected path alone when it is still absent", context do
    approved = approved(context, %{"tools/missing.exs" => Workspace.absent_digest()})

    assert {:ok, []} = Workspace.restore_protected(approved)
  end

  defp approved(context, approved_sha) when is_binary(approved_sha),
    do: approved(context, %{@path => approved_sha})

  defp approved(context, manifest) do
    %{
      workdir: context.workdir,
      origin: context.origin,
      base_sha: context.base_sha,
      slug: "guard-fixture",
      intent_bytes: "",
      acceptance_files: %{},
      manifest: manifest,
      git_env: Git.env()
    }
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
