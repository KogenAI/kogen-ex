defmodule Kogen.Kernel.IntentRemovalTest do
  use Kogen.Testkit.Case

  alias Kogen.Kernel.IntentRemoval
  alias Kogen.Kernel.Types.IntentStatus
  alias Kogen.Testkit.Git
  alias Kogen.Workspace

  test "removes only the Intent files in one commit", %{tmp_dir: tmp_dir} do
    repo = seed_intent!(tmp_dir)
    Git.git!(repo, ["add", "README.md"])
    File.write!(Path.join(repo, "README.md"), "staged unrelated change\n")
    Git.git!(repo, ["add", "README.md"])

    assert {:ok, commit} =
             IntentRemoval.remove("remove-me", repo, repo, status(:draft), false, Git.env())

    assert Git.git!(repo, ["show", "-s", "--format=%s", commit]) == "Remove Intent remove-me\n"
    assert Git.git!(repo, ["show", "#{commit}:README.md"]) == "fixture\n"
    assert Git.git!(repo, ["status", "--short"]) =~ "README.md"
    refute File.exists?(Path.join(repo, ".kogen/intents/remove-me"))
    refute File.exists?(Path.join(repo, ".kogen/acceptance/remove-me_test.exs"))
  end

  test "an approved Intent needs force, then its approval ref is removed", %{tmp_dir: tmp_dir} do
    repo = seed_intent!(tmp_dir)
    sha = repo |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()
    assert :ok = Workspace.ref_create(repo, "refs/kogen/intents/remove-me", sha, Git.env())

    assert {:error, {:intent_remove_requires_force, "approved"}} =
             IntentRemoval.remove("remove-me", repo, repo, status(:approved), false, Git.env())

    assert File.exists?(Path.join(repo, ".kogen/intents/remove-me/intent.md"))

    assert {:ok, _commit} =
             IntentRemoval.remove("remove-me", repo, repo, status(:approved), true, Git.env())

    assert {:error, :missing} =
             Workspace.ref_read(repo, "refs/kogen/intents/remove-me", Git.env())
  end

  test "a running Build cannot be removed even with force", %{tmp_dir: tmp_dir} do
    repo = seed_intent!(tmp_dir)

    assert {:error, :intent_is_building} =
             IntentRemoval.remove("remove-me", repo, repo, status(:building), true, Git.env())

    assert File.exists?(Path.join(repo, ".kogen/intents/remove-me/intent.md"))
  end

  test "Git resolves the caller's approval identity", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)

    assert {:ok, "Kogen Test <test@kogen.invalid>"} = Workspace.git_identity(repo, Git.env())
  end

  defp seed_intent!(tmp_dir) do
    repo = Git.create!(tmp_dir)
    write!(repo, ".kogen/intents/remove-me/intent.md", "---\ntitle: Remove me\n---\n")
    write!(repo, ".kogen/acceptance/remove-me_test.exs", "defmodule RemoveMeTest do end\n")
    Git.git!(repo, ["add", "--all"])
    Git.git!(repo, ["commit", "--quiet", "-m", "Add removable Intent"])
    repo
  end

  defp status(state) do
    %IntentStatus{slug: "remove-me", status: state, run_id: nil, landed_sha: nil}
  end

  defp write!(root, relative, bytes) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end
end
