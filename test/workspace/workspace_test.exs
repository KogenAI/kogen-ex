defmodule Kogen.Workspace.WorkspaceTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Workspace

  @git_env %{
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_AUTHOR_NAME" => "Kogen Test",
    "GIT_AUTHOR_EMAIL" => "test@kogen.invalid",
    "GIT_COMMITTER_NAME" => "Kogen Test",
    "GIT_COMMITTER_EMAIL" => "test@kogen.invalid",
    "GIT_AUTHOR_DATE" => "2026-10-02T00:00:00+00:00",
    "GIT_COMMITTER_DATE" => "2026-10-02T00:00:00+00:00",
    "GIT_TERMINAL_PROMPT" => "0",
    "GIT_OPTIONAL_LOCKS" => "0"
  }

  test "clones a base detached, seeds build artifacts, hashes private working trees, and inserts files",
       %{
         tmp_dir: tmp_dir
       } do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)
    File.mkdir_p!(Path.join(source, "deps"))
    File.mkdir_p!(Path.join(source, "_build"))
    File.write!(Path.join([source, "deps", "seed.txt"]), "deps seed")
    File.write!(Path.join([source, "_build", "seed.txt"]), "build seed")

    assert {:ok, %{path: candidate, base_sha: ^base_sha}} =
             Workspace.create(source, base_sha, workspace_root(tmp_dir), "clone-seed", @git_env)

    assert File.read!(Path.join([candidate, "deps", "seed.txt"])) == "deps seed"
    assert File.read!(Path.join([candidate, "_build", "seed.txt"])) == "build seed"

    assert {:ok, first_tree} = Workspace.tree_hash(candidate, @git_env)
    assert {:ok, ^first_tree} = Workspace.tree_hash(candidate, @git_env)
    File.write!(Path.join(candidate, "README.md"), "edited\n")
    assert {:ok, edited_tree} = Workspace.tree_hash(candidate, @git_env)
    refute edited_tree == first_tree
    assert {:ok, ["README.md"]} = Workspace.changed_paths(candidate, base_sha, @git_env)

    assert :ok =
             Workspace.insert_files(candidate, %{
               "test/acceptance/frozen_test.exs" => "binary\0artifact"
             })

    assert File.read!(Path.join([candidate, "test", "acceptance", "frozen_test.exs"])) ==
             "binary\0artifact"

    assert {:ok, diff} = Workspace.diff(candidate, base_sha, @git_env)
    assert diff =~ "README.md"
    assert diff =~ "edited"
    assert diff =~ "frozen_test.exs"

    assert {:ok, implementation_diff} =
             Workspace.diff_excluding(
               candidate,
               base_sha,
               ["test/acceptance/frozen_test.exs"],
               @git_env
             )

    assert implementation_diff =~ "README.md"
    refute implementation_diff =~ "frozen_test.exs"
    refute implementation_diff =~ "binary"
    assert :ok = git!(candidate, ["diff", "--cached", "--quiet"])

    assert {:error, :invalid_files} = Workspace.insert_files(candidate, %{"../escape" => "no"})

    assert {:ok, commit_sha} =
             Workspace.commit(
               candidate,
               "Install frozen acceptance artifact",
               [{"Kogen-Intent", "feature"}, {"Kogen-Receipt", "tree123"}],
               @git_env
             )

    assert :ok = Workspace.rebase(candidate, source, base_sha, @git_env)

    assert {:ok, message} = Workspace.commit_message(candidate, commit_sha, @git_env)
    assert message =~ "Kogen-Intent: feature"
    assert message =~ "Kogen-Receipt: tree123"

    assert {:ok, "edited\n"} =
             Workspace.read_file_at(candidate, commit_sha, "README.md", @git_env)

    assert {:error, :missing} =
             Workspace.read_file_at(candidate, commit_sha, "missing.txt", @git_env)

    assert Workspace.ancestor?(candidate, base_sha, commit_sha, @git_env)
  end

  test "ref helpers create once and compare old values atomically", %{tmp_dir: tmp_dir} do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)
    File.write!(Path.join(source, "README.md"), "next\n")
    git!(source, ["add", "--all"])
    git!(source, ["commit", "--quiet", "-m", "next"])
    next_sha = source |> git_output!(["rev-parse", "HEAD"]) |> String.trim()
    ref = "refs/kogen/test/claim"

    assert {:error, :missing} = Workspace.ref_read(source, ref, @git_env)
    assert :ok = Workspace.ref_create(source, ref, base_sha, @git_env)
    assert {:error, :exists} = Workspace.ref_create(source, ref, next_sha, @git_env)
    assert {:ok, ^base_sha} = Workspace.ref_read(source, ref, @git_env)
    assert {:error, :stale} = Workspace.ref_update(source, ref, next_sha, next_sha, @git_env)
    assert :ok = Workspace.ref_update(source, ref, next_sha, base_sha, @git_env)
    assert {:ok, ^next_sha} = Workspace.ref_read(source, ref, @git_env)
    assert {:error, :stale} = Workspace.ref_delete(source, ref, base_sha, @git_env)
    assert :ok = Workspace.ref_delete(source, ref, next_sha, @git_env)
    assert {:error, :missing} = Workspace.ref_read(source, ref, @git_env)

    assert {:ok, clean_tree} = Workspace.tree_hash(source, @git_env)

    assert {:ok, state_sha} =
             Workspace.commit_tree_with_files(
               source,
               %{".kogen/state/run.json" => "{\"run\":true}"},
               [base_sha],
               "record state",
               @git_env
             )

    assert {:ok, "{\"run\":true}"} =
             Workspace.read_file_at(source, state_sha, ".kogen/state/run.json", @git_env)

    assert Workspace.ancestor?(source, base_sha, state_sha, @git_env)
    assert {:ok, ^clean_tree} = Workspace.tree_hash(source, @git_env)
  end

  test "ancestor returns process errors instead of treating them as a negative answer",
       %{tmp_dir: tmp_dir} do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)
    git_env = Map.put(@git_env, "PATH", Path.join(tmp_dir, "missing-bin"))

    assert {:error, :enoent} = Workspace.ancestor?(source, base_sha, base_sha, git_env)
  end

  test "soft reset moves candidate commits onto the approved base", %{tmp_dir: tmp_dir} do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)

    assert {:ok, %{path: candidate}} =
             Workspace.create(source, base_sha, workspace_root(tmp_dir), "reset-soft", @git_env)

    File.write!(Path.join(candidate, "README.md"), "candidate\n")
    assert {:ok, _commit_sha} = Workspace.commit(candidate, "candidate", [], @git_env)
    assert :ok = Workspace.reset_soft(candidate, base_sha, @git_env)
    assert {:ok, ^base_sha} = Workspace.rev_parse(candidate, "HEAD", @git_env)
    assert {:ok, ["README.md"]} = Workspace.changed_paths(candidate, base_sha, @git_env)
  end

  test "rebases a candidate onto a moved base from its origin", %{tmp_dir: tmp_dir} do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)
    origin = bare_origin!(source, tmp_dir)

    assert {:ok, %{path: candidate}} =
             Workspace.create(origin, base_sha, workspace_root(tmp_dir), "rebase-moved", @git_env)

    File.write!(Path.join(candidate, "candidate.txt"), "candidate\n")
    assert {:ok, _candidate_sha} = Workspace.commit(candidate, "candidate", [], @git_env)

    assert {:ok, moved_sha} =
             Workspace.commit_tree_with_files(
               origin,
               %{"base.txt" => "new base\n"},
               [base_sha],
               "advance base",
               @git_env
             )

    assert :ok = Workspace.ref_update(origin, "refs/heads/main", moved_sha, base_sha, @git_env)
    assert :ok = Workspace.rebase(candidate, origin, moved_sha, @git_env)
    assert {:ok, ^moved_sha} = Workspace.rev_parse(candidate, "HEAD^", @git_env)
    assert {:ok, "new base\n"} = Workspace.read_file_at(candidate, "HEAD", "base.txt", @git_env)

    assert {:ok, "candidate\n"} =
             Workspace.read_file_at(candidate, "HEAD", "candidate.txt", @git_env)
  end

  test "candidate git config cannot hide, transform, sign, or hook the guarded tree", %{
    tmp_dir: tmp_dir
  } do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)

    assert {:ok, %{path: candidate}} =
             Workspace.create(
               source,
               base_sha,
               workspace_root(tmp_dir),
               "git-isolation",
               @git_env
             )

    hook_dir = Path.join(tmp_dir, "candidate-hooks")
    File.mkdir_p!(hook_dir)
    hook = Path.join(hook_dir, "pre-commit")
    File.write!(hook, "#!/bin/sh\nprintf ran > #{Path.join(candidate, "hook-ran")}\n")
    File.chmod!(hook, 0o755)
    git!(candidate, ["config", "core.hooksPath", hook_dir])
    git!(candidate, ["config", "core.fsmonitor", "true"])
    git!(candidate, ["config", "core.excludesFile", Path.join(tmp_dir, "candidate-excludes")])
    git!(candidate, ["config", "commit.gpgsign", "true"])
    git!(candidate, ["config", "gpg.program", "/missing-test-gpg"])
    git!(candidate, ["config", "filter.evil.clean", "touch clean-filter-ran; cat"])
    git!(candidate, ["config", "filter.evil.smudge", "touch smudge-filter-ran; cat"])
    File.write!(Path.join(candidate, ".gitattributes"), "*.filtered filter=evil\n")
    File.write!(Path.join(candidate, "value.filtered"), "original filter content\n")
    File.write!(Path.join(candidate, "hidden.txt"), "excluded content\n")
    File.write!(Path.join([candidate, ".git", "info", "exclude"]), "hidden.txt\n")

    assert {:ok, tree} = Workspace.tree_hash(candidate, @git_env)
    assert {:ok, paths} = Workspace.changed_paths(candidate, base_sha, @git_env)
    assert paths == [".gitattributes", "hidden.txt", "value.filtered"]
    assert File.read!(Path.join([candidate, ".git", "info", "exclude"])) == "hidden.txt\n"

    assert {:ok, commit} = Workspace.commit(candidate, "candidate tree", [], @git_env)
    assert {:ok, ^tree} = Workspace.rev_parse(candidate, "HEAD^{tree}", @git_env)

    assert {:ok, "original filter content\n"} =
             Workspace.read_file_at(candidate, commit, "value.filtered", @git_env)

    refute File.exists?(Path.join(candidate, "hook-ran"))
    refute File.exists?(Path.join(candidate, "clean-filter-ran"))
    refute File.exists?(Path.join(candidate, "smudge-filter-ran"))
  end

  test "lands a single-parent commit through a temporary ref and removes the temporary ref", %{
    tmp_dir: tmp_dir
  } do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)
    origin = bare_origin!(source, tmp_dir)

    assert {:ok, %{path: candidate}} =
             Workspace.create(origin, base_sha, workspace_root(tmp_dir), "land-success", @git_env)

    File.write!(Path.join(candidate, "README.md"), "landed\n")
    assert {:ok, commit_sha} = Workspace.commit(candidate, "land me", [], @git_env)

    File.write!(Path.join(candidate, "README.md"), "changed after commit\n")

    assert {:error, :tree_mismatch} =
             Workspace.land(candidate, origin, "main", base_sha, "run-mismatch", @git_env)

    File.write!(Path.join(candidate, "README.md"), "landed\n")

    assert {:ok, []} =
             Workspace.land(candidate, origin, "main", base_sha, "run-success", @git_env)

    assert {:ok, ^commit_sha} = Workspace.ref_read(origin, "refs/heads/main", @git_env)

    assert {:error, :missing} =
             Workspace.ref_read(origin, "refs/kogen/incoming/run-success", @git_env)

    refute File.exists?(Path.join(origin, "refs/heads/main.lock"))
  end

  test "seeds deps and build artifacts from a checkout when the origin is bare", %{
    tmp_dir: tmp_dir
  } do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)
    File.mkdir_p!(Path.join(source, "deps"))
    File.mkdir_p!(Path.join(source, "_build"))
    File.write!(Path.join([source, "deps", "seed.txt"]), "deps seed")
    File.write!(Path.join([source, "_build", "seed.txt"]), "build seed")
    origin = bare_origin!(source, tmp_dir)

    assert {:ok, %{path: candidate}} =
             Workspace.create(
               origin,
               base_sha,
               workspace_root(tmp_dir),
               "bare-seed",
               @git_env,
               seed_from: source
             )

    assert File.read!(Path.join([candidate, "deps", "seed.txt"])) == "deps seed"
    assert File.read!(Path.join([candidate, "_build", "seed.txt"])) == "build seed"
  end

  test "refuses a moved base and leaves no incoming ref or ref lock", %{tmp_dir: tmp_dir} do
    %{source: source, base_sha: base_sha} = fixture(tmp_dir)
    origin = bare_origin!(source, tmp_dir)

    assert {:ok, %{path: candidate}} =
             Workspace.create(origin, base_sha, workspace_root(tmp_dir), "land-moved", @git_env)

    File.write!(Path.join(candidate, "README.md"), "candidate\n")
    assert {:ok, candidate_sha} = Workspace.commit(candidate, "candidate", [], @git_env)

    assert {:ok, moved_sha} =
             Workspace.commit_tree_with_files(
               origin,
               %{"README.md" => "moved\n"},
               [base_sha],
               "move origin",
               @git_env
             )

    assert :ok = Workspace.ref_update(origin, "refs/heads/main", moved_sha, base_sha, @git_env)

    assert {:error, :base_moved} =
             Workspace.land(candidate, origin, "main", base_sha, "run-moved", @git_env)

    assert {:ok, ^moved_sha} = Workspace.ref_read(origin, "refs/heads/main", @git_env)

    assert {:error, :not_fast_forward} =
             Workspace.land(candidate, origin, "main", moved_sha, "run-parent", @git_env)

    assert {:error, :missing} =
             Workspace.ref_read(origin, "refs/kogen/incoming/run-moved", @git_env)

    lock_path = Path.join(origin, "refs/heads/main.lock")
    File.write!(lock_path, "preserve this lock")

    assert {:error, :ref_locked} =
             Workspace.land(candidate, origin, "main", moved_sha, "run-locked", @git_env)

    assert File.read!(lock_path) == "preserve this lock"

    assert {:error, :missing} =
             Workspace.ref_read(origin, "refs/kogen/incoming/run-locked", @git_env)

    assert :ok = Workspace.park(candidate, origin, "run-parked", @git_env)

    assert {:ok, ^candidate_sha} =
             Workspace.ref_read(origin, "refs/kogen/parked/run-parked", @git_env)

    refute File.exists?(candidate)
  end

  defp fixture(tmp_dir) do
    source = Kogen.Testkit.Git.create!(Path.join(tmp_dir, "source-area"))
    File.write!(Path.join(source, ".gitignore"), "deps/\n_build/\n")
    git!(source, ["add", "--all"])
    git!(source, ["commit", "--quiet", "-m", "fixture rules"])
    git!(source, ["branch", "-M", "main"])
    %{source: source, base_sha: source |> git_output!(["rev-parse", "HEAD"]) |> String.trim()}
  end

  defp workspace_root(tmp_dir), do: Path.join([tmp_dir, ".kogen", "workspaces", "workspace-test"])

  defp bare_origin!(source, tmp_dir) do
    origin = Path.join(tmp_dir, "origin.git")
    git!(tmp_dir, ["clone", "--bare", "--local", source, origin])
    origin
  end

  defp git!(repo, args) do
    assert {:ok, %ProcResult{exit_status: 0, timed_out: false}} = run_git(repo, args)

    :ok
  end

  defp git_output!(repo, args) do
    assert {:ok, %ProcResult{exit_status: 0, timed_out: false, output_tail: output}} =
             run_git(repo, args)

    output
  end

  defp run_git(repo, args) do
    git_dir = Path.join(repo, ".git")
    log_dir = if File.dir?(git_dir), do: git_dir, else: repo
    log_path = Path.join(log_dir, "kogen-test-git-#{System.unique_integer([:positive])}.log")

    result =
      Kogen.Workspace.Process.run(["git" | args],
        cd: repo,
        env: @git_env,
        log_path: log_path
      )

    case File.rm(log_path) do
      :ok -> result
      {:error, :enoent} -> result
      {:error, reason} -> flunk("could not remove test Git log: #{inspect(reason)}")
    end
  end
end
