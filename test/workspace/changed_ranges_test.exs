defmodule Kogen.Workspace.ChangedRangesTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Testkit.Git
  alias Kogen.Workspace

  test "ranges describe changed, added and removed lines without content or index writes", %{
    tmp_dir: tmp_dir
  } do
    repo = Git.create!(tmp_dir)
    path = Path.join(repo, "lines.txt")
    File.write!(path, "first\nsecond\nthird\nfourth\nfifth\n")
    File.write!(Path.join(repo, "removed.txt"), "removed\n")
    Git.git!(repo, ["add", "--all"])
    Git.git!(repo, ["commit", "--quiet", "-m", "Range fixture"])
    base = repo |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()
    index = File.read!(Path.join(repo, ".git/index"))
    File.write!(path, "first\ncandidate-secret\nthird\nfourth\nfifth\nadded\n")
    File.write!(Path.join(repo, "new file.txt"), "new\nlines\n")
    File.rm!(Path.join(repo, "removed.txt"))

    assert {:ok, ranges} = Workspace.changed_line_ranges(repo, base, Git.env())
    assert "lines.txt: base 2 -> candidate 2" in ranges
    assert "lines.txt: base 5 -> candidate 6" in ranges
    assert "new file.txt: base 0 -> candidate 1-2" in ranges
    assert "removed.txt: base 1 -> candidate 0" in ranges
    refute Enum.join(ranges) =~ "candidate-secret"
    assert File.read!(Path.join(repo, ".git/index")) == index
  end

  test "at most thirty range entries are returned", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    base = repo |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()
    for number <- 1..35, do: File.write!(Path.join(repo, "new-#{number}.txt"), "new\n")
    assert {:ok, ranges} = Workspace.changed_line_ranges(repo, base, Git.env())
    assert length(ranges) == 30
    assert Enum.all?(ranges, &String.ends_with?(&1, ": base 0 -> candidate 1"))
  end
end
