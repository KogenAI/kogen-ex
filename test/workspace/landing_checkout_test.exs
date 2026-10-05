defmodule Kogen.Workspace.LandingCheckoutTest do
  use Kogen.Testkit.Case

  alias Kogen.Testkit.Git
  alias Kogen.Workspace

  @git_env Git.env()

  test "updates a clean checkout of the landed branch", %{tmp_dir: tmp_dir} do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)
    {candidate, sha} = candidate!(source, tmp_dir, base_sha, "clean")

    assert {:ok, []} = Workspace.land(candidate, source, "main", base_sha, "run-clean", @git_env)

    assert head(source) == sha
    assert File.read!(Path.join(source, "README.md")) == "landed\n"
    assert Git.git!(source, ["status", "--porcelain"]) == ""
  end

  test "leaves a checkout with unrelated local edits entirely untouched", %{tmp_dir: tmp_dir} do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)
    {candidate, _sha} = candidate!(source, tmp_dir, base_sha, "unrelated")
    File.write!(Path.join(source, "notes.txt"), "my edit\n")
    File.write!(Path.join(source, "scratch.txt"), "untracked\n")

    assert {:ok, [_warning]} =
             Workspace.land(candidate, source, "main", base_sha, "run-unrelated", @git_env)

    assert File.read!(Path.join(source, "README.md")) == "fixture\n"
    assert File.read!(Path.join(source, "notes.txt")) == "my edit\n"
    assert File.read!(Path.join(source, "scratch.txt")) == "untracked\n"
  end

  for {name, setup} <- [
        {"unstaged edit", :unstaged},
        {"staged edit", :staged},
        {"untracked file in the way", :untracked}
      ] do
    test "lands but leaves a checkout with #{name} untouched and warns", %{tmp_dir: tmp_dir} do
      %{source: source, base_sha: base_sha} = fixture(tmp_dir)
      {candidate, sha} = candidate!(source, tmp_dir, base_sha, "dirty")
      {local_path, local} = dirty!(source, unquote(setup))

      assert {:ok, [warning]} =
               Workspace.land(candidate, source, "main", base_sha, "run-dirty", @git_env)

      assert unprivate(warning.path) == source

      assert unprivate(warning.detail) ==
               "landed #{sha} on main; your checkout at #{source} has local changes and was " <>
                 "not updated; run `git reset --keep #{sha}`, or merge it yourself"

      assert {:ok, ^sha} = Workspace.ref_read(source, "refs/heads/main", @git_env)
      assert File.read!(local_path) == local
    end
  end

  test "updates a linked worktree that has the branch checked out", %{tmp_dir: tmp_dir} do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)
    origin = Path.join(tmp_dir, "origin.git")
    Git.git!(tmp_dir, ["clone", "--bare", "--local", source, origin])
    linked = Path.join(tmp_dir, "linked")
    Git.git!(origin, ["worktree", "add", "--quiet", linked, "main"])
    {candidate, sha} = candidate!(origin, tmp_dir, base_sha, "linked")

    assert {:ok, []} = Workspace.land(candidate, origin, "main", base_sha, "run-linked", @git_env)

    assert head(linked) == sha
    assert File.read!(Path.join(linked, "README.md")) == "landed\n"
    assert Git.git!(linked, ["status", "--porcelain"]) == ""
  end

  test "warns only for the linked worktree that has local changes", %{tmp_dir: tmp_dir} do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)
    {candidate, _sha} = candidate!(source, tmp_dir, base_sha, "two")
    Git.git!(source, ["switch", "--quiet", "--detach"])
    linked = Path.join(tmp_dir, "linked")
    Git.git!(source, ["worktree", "add", "--quiet", linked, "main"])
    File.write!(Path.join(linked, "README.md"), "mine\n")

    assert {:ok, [warning]} =
             Workspace.land(candidate, source, "main", base_sha, "run-two", @git_env)

    assert unprivate(warning.path) == linked

    assert File.read!(Path.join(linked, "README.md")) == "mine\n"
  end

  defp dirty!(source, :unstaged) do
    path = Path.join(source, "README.md")
    File.write!(path, "local\n")
    {path, "local\n"}
  end

  defp dirty!(source, :staged) do
    path = Path.join(source, "README.md")
    File.write!(path, "staged\n")
    Git.git!(source, ["add", "README.md"])
    {path, "staged\n"}
  end

  defp dirty!(source, :untracked) do
    # The landed tree adds NEW.md, which already exists locally as an untracked file.
    path = Path.join(source, "NEW.md")
    File.write!(path, "local\n")
    {path, "local\n"}
  end

  defp candidate!(origin, tmp_dir, base_sha, id) do
    root = Path.join([tmp_dir, ".kogen", "workspaces", "landing-checkout"])
    assert {:ok, %{path: candidate}} = Workspace.create(origin, base_sha, root, id, @git_env)
    File.write!(Path.join(candidate, "README.md"), "landed\n")
    File.write!(Path.join(candidate, "NEW.md"), "landed\n")
    assert {:ok, sha} = Workspace.commit(candidate, "land me", [], @git_env)
    {candidate, sha}
  end

  defp fixture(tmp_dir) do
    source = Git.create!(Path.join(tmp_dir, "source-area"))
    File.write!(Path.join(source, "notes.txt"), "notes\n")
    Git.git!(source, ["add", "--all"])
    Git.git!(source, ["commit", "--quiet", "-m", "notes"])
    Git.git!(source, ["branch", "-M", "main"])
    %{source: source, base_sha: head(source)}
  end

  # Git reports macOS temporary directories by their canonical /private path.
  defp unprivate(text), do: String.replace(text, "/private/var/", "/var/")

  defp head(repo), do: repo |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()
end
