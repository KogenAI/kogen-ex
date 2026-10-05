defmodule Kogen.Checks.ProtectedViolationsTest do
  use Kogen.Testkit.Case

  alias Kogen.Checks
  alias Kogen.Testkit.Git

  test "protected paths approved as absent fail only once created", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    base_sha = commit_base!(repo, [])
    manifest = %{".dialyzer_ignore.exs" => Kogen.Workspace.absent_digest()}

    assert {:ok, []} = Checks.protected_violations(repo, base_sha, manifest, Git.env())

    File.write!(Path.join(repo, ".dialyzer_ignore.exs"), "[]\n")

    assert {:ok, [".dialyzer_ignore.exs"]} =
             Checks.protected_violations(repo, base_sha, manifest, Git.env())
  end

  test "a protected file that cannot be read is an error, not a pass", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    base_sha = commit_base!(repo, [{".gitignore", "locked.exs\n"}])
    secret = Path.join(repo, "locked.exs")
    File.write!(secret, "x\n")
    File.chmod!(secret, 0o000)
    on_exit(fn -> File.chmod(secret, 0o600) end)

    manifest = %{"locked.exs" => sha256("x\n")}

    assert {:error, {:protected_unreadable, "locked.exs", :eacces}} =
             Checks.protected_violations(repo, base_sha, manifest, Git.env())
  end

  defp commit_base!(repo, files) do
    for {path, contents} <- files do
      File.write!(Path.join(repo, path), contents)
      Git.git!(repo, ["add", path])
    end

    Git.git!(repo, ["commit", "--quiet", "--allow-empty", "-m", "base"])
    repo |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
end
