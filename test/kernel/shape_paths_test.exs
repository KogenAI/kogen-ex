defmodule Kogen.Kernel.ShapePathsTest do
  use Kogen.Testkit.Case

  alias Kogen.Kernel.ShapePaths
  alias Kogen.Testkit.Git

  test "setup cache is keyed by the HEAD tree of the project", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    File.write!(Path.join(repo, "a.txt"), "a\n")
    Git.git!(repo, ["add", "a.txt"])
    Git.git!(repo, ["commit", "--quiet", "-m", "base"])
    tree = repo |> Git.git!(["rev-parse", "HEAD^{tree}"]) |> String.trim()

    assert {:ok, {cache_root, ^tree}} =
             ShapePaths.setup_cache(repo, Path.join(tmp_dir, "home"), Git.env())

    assert Path.basename(cache_root) == "setup-cache"
  end

  test "setup cache reports a project whose tree cannot be read", %{tmp_dir: tmp_dir} do
    plain = Path.join(tmp_dir, "not-a-repo")
    File.mkdir_p!(plain)

    assert {:error, _reason} =
             ShapePaths.setup_cache(plain, Path.join(tmp_dir, "home"), Git.env())
  end
end
