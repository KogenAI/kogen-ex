defmodule Kogen.Workspace do
  @moduledoc "Creates isolated checkouts and performs safe Git ref operations."
  use Boundary, deps: [Kogen.Contracts, Kogen.Proc], exports: []

  alias Kogen.Workspace.ApprovalManifest
  alias Kogen.Workspace.ApprovedFile
  alias Kogen.Workspace.BaseGlob
  alias Kogen.Workspace.Checkout
  alias Kogen.Workspace.Diff
  alias Kogen.Workspace.Guard
  alias Kogen.Workspace.Identity
  alias Kogen.Workspace.Index
  alias Kogen.Workspace.IntentFiles
  alias Kogen.Workspace.Landing
  alias Kogen.Workspace.ProtectedRestore
  alias Kogen.Workspace.Rebase
  alias Kogen.Workspace.Refs
  alias Kogen.Workspace.StatusRefs

  @type git_env :: %{String.t() => String.t()}

  @spec create(Path.t(), String.t(), Path.t(), String.t(), git_env()) ::
          {:ok, %{path: Path.t(), base_sha: String.t()}} | {:error, term()}
  @spec create(Path.t(), String.t(), Path.t(), String.t(), git_env(), keyword()) ::
          {:ok, %{path: Path.t(), base_sha: String.t()}} | {:error, term()}
  def create(origin, base_sha, root, build_id, git_env, options \\ []) do
    Checkout.create(origin, base_sha, root, build_id, git_env, options)
  end

  @spec insert_files(Path.t(), %{String.t() => binary()}) :: :ok | {:error, term()}
  def insert_files(path, files), do: Checkout.insert_files(path, files)

  @spec install_intent_files(Path.t(), String.t(), binary(), %{String.t() => binary()}) ::
          :ok | {:error, term()}
  def install_intent_files(workdir, slug, intent_bytes, acceptance_files),
    do: IntentFiles.install(workdir, slug, intent_bytes, acceptance_files)

  @spec remove_acceptance_source(Path.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def remove_acceptance_source(workdir, slug),
    do: IntentFiles.remove_acceptance_source(workdir, slug)

  @spec approval_manifest_unchanged_between(
          Path.t(),
          String.t(),
          String.t(),
          %{String.t() => String.t()},
          git_env()
        ) :: :ok | {:error, term()}
  def approval_manifest_unchanged_between(origin, approved_sha, current_sha, manifest, git_env),
    do: ApprovalManifest.unchanged_between(origin, approved_sha, current_sha, manifest, git_env)

  @spec build_base(Path.t(), String.t(), map(), git_env()) ::
          {:ok, String.t(), map(), [String.t()]} | {:error, term()}
  def build_base(origin, branch, approval, git_env),
    do: ApprovalManifest.build_base(origin, branch, approval, git_env)

  @spec refresh_manifest(Path.t(), String.t(), map(), git_env()) ::
          {:ok, map(), [String.t()]} | {:error, term()}
  def refresh_manifest(origin, current, approval, git_env),
    do: ApprovalManifest.refresh(origin, current, approval, git_env)

  @spec tree_hash(Path.t(), git_env()) :: {:ok, String.t()} | {:error, term()}
  def tree_hash(path, git_env), do: Checkout.tree_hash(path, git_env)

  @spec restore_check_tree(Path.t(), String.t(), [String.t()], git_env()) ::
          :ok | {:error, term()}
  def restore_check_tree(path, tree, paths, env),
    do: Kogen.Workspace.CheckTree.restore(path, tree, paths, env)

  @spec copy_on_write(Path.t(), Path.t()) :: :ok | {:error, term()}
  def copy_on_write(source, destination),
    do: Kogen.Workspace.Copy.copy_on_write(source, destination)

  @spec diff(Path.t(), String.t(), git_env()) :: {:ok, binary()} | {:error, term()}
  def diff(path, base_sha, git_env), do: Diff.diff(path, base_sha, git_env)

  @spec diff_excluding(Path.t(), String.t(), [String.t()], git_env()) ::
          {:ok, binary()} | {:error, term()}
  def diff_excluding(path, base_sha, excluded_paths, git_env),
    do: Diff.diff_excluding(path, base_sha, excluded_paths, git_env)

  @spec changed_paths(Path.t(), String.t(), git_env()) ::
          {:ok, [String.t()]} | {:error, term()}
  def changed_paths(path, base_sha, git_env), do: Checkout.changed_paths(path, base_sha, git_env)

  @spec changed_line_ranges(Path.t(), String.t(), git_env()) ::
          {:ok, [String.t()]} | {:error, term()}
  def changed_line_ranges(path, base, env),
    do: Kogen.Workspace.ChangedRanges.changed_line_ranges(path, base, env)

  @spec commit(Path.t(), String.t(), [{String.t(), String.t()}], git_env()) ::
          {:ok, String.t()} | {:error, term()}
  def commit(path, message, trailers, git_env),
    do: Checkout.commit(path, message, trailers, git_env)

  @spec commit_paths(Path.t(), String.t(), [String.t()], [{String.t(), String.t()}], git_env()) ::
          {:ok, String.t()} | {:error, term()}
  def commit_paths(path, message, paths, trailers, git_env),
    do: Checkout.commit_paths(path, message, paths, trailers, git_env)

  @spec git_identity(Path.t(), git_env()) :: {:ok, String.t()} | {:error, term()}
  def git_identity(repo, git_env), do: Identity.read(repo, git_env)

  @spec tracked_paths(Path.t(), String.t(), git_env()) :: {:ok, [String.t()]} | {:error, term()}
  def tracked_paths(repo, pathspec, git_env), do: Index.tracked_paths(repo, pathspec, git_env)

  @spec reset_soft(Path.t(), String.t(), git_env()) :: :ok | {:error, term()}
  def reset_soft(path, base_sha, git_env), do: Checkout.reset_soft(path, base_sha, git_env)

  @spec rebase(Path.t(), Path.t(), String.t(), git_env()) :: :ok | {:error, term()}
  def rebase(path, origin, base_sha, git_env), do: Rebase.run(path, origin, base_sha, git_env)

  @spec land(Path.t(), Path.t(), String.t(), String.t(), String.t(), git_env()) ::
          {:ok, [%{path: Path.t(), detail: String.t()}]} | {:error, term()}
  def land(path, origin, branch, expected_old_sha, run_id, git_env),
    do: Landing.land(path, origin, branch, expected_old_sha, run_id, git_env)

  @spec park(Path.t(), Path.t(), String.t(), git_env()) :: :ok | {:error, term()}
  def park(path, origin, run_id, git_env), do: Landing.park(path, origin, run_id, git_env)

  @spec destroy(Path.t()) :: :ok | {:error, term()}
  def destroy(path), do: Checkout.destroy(path)

  @spec checkout_glob(Path.t(), [String.t()]) :: [String.t()]
  def checkout_glob(root, patterns), do: BaseGlob.checkout(root, patterns)

  @spec tree_glob([String.t()], [String.t()], Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def tree_glob(base_paths, patterns, tmp_dir), do: BaseGlob.tree(base_paths, patterns, tmp_dir)

  @doc "Manifest digest meaning the protected path must stay absent."
  @spec absent_digest() :: String.t()
  def absent_digest, do: Guard.absent_digest()

  @spec protected_violations(Path.t(), String.t(), %{String.t() => String.t()}, git_env()) ::
          {:ok, [String.t()]} | {:error, term()}
  def protected_violations(workdir, base_sha, manifest, git_env),
    do: Guard.protected_violations(workdir, base_sha, manifest, git_env)

  @doc "Restores protected Candidate paths to their approved bytes; returns the restored paths."
  @spec restore_protected(ProtectedRestore.approved()) :: {:ok, [String.t()]} | {:error, term()}
  def restore_protected(approved), do: ProtectedRestore.restore(approved)

  @spec scope_violations(
          Path.t(),
          String.t(),
          Kogen.Contracts.Intent.t(),
          Kogen.Contracts.Project.t(),
          [String.t()],
          git_env()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def scope_violations(workdir, base_sha, intent, project, allowed_extra, git_env),
    do: Guard.scope_violations(workdir, base_sha, intent, project, allowed_extra, git_env)

  @spec remote_url(Path.t(), String.t(), git_env()) :: {:ok, String.t()} | {:error, term()}
  def remote_url(repo, remote, git_env), do: Refs.remote_url(repo, remote, git_env)

  @spec head_branch(Path.t(), git_env()) :: {:ok, String.t()} | {:error, term()}
  def head_branch(repo, git_env), do: StatusRefs.head_branch(repo, git_env)

  @spec remote_head_branch(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def remote_head_branch(repo, remote), do: StatusRefs.remote_head_branch(repo, remote)

  @doc false
  @spec status_snapshot(Path.t(), String.t(), git_env()) ::
          {:ok, StatusRefs.snapshot()} | {:error, term()}
  def status_snapshot(repo, branch, git_env), do: StatusRefs.snapshot(repo, branch, git_env, true)

  @doc false
  @spec status_snapshot(Path.t(), String.t(), git_env(), boolean()) ::
          {:ok, StatusRefs.snapshot()} | {:error, term()}
  def status_snapshot(repo, branch, git_env, include_claim?),
    do: StatusRefs.snapshot(repo, branch, git_env, include_claim?)

  @spec ref_read(Path.t(), String.t(), git_env()) ::
          {:ok, String.t()} | {:error, :missing | term()}
  def ref_read(repo, ref, git_env), do: Refs.ref_read(repo, ref, git_env)

  @spec ref_create(Path.t(), String.t(), String.t(), git_env()) ::
          :ok | {:error, :exists | term()}
  def ref_create(repo, ref, sha, git_env), do: Refs.ref_create(repo, ref, sha, git_env)

  @spec ref_update(Path.t(), String.t(), String.t(), String.t(), git_env()) ::
          :ok | {:error, :stale | term()}
  def ref_update(repo, ref, new_sha, old_sha, git_env),
    do: Refs.ref_update(repo, ref, new_sha, old_sha, git_env)

  @doc "Points `refs/heads/<branch>` at `sha`, creating the branch or moving it there."
  @spec publish_branch(Path.t(), String.t(), String.t(), git_env()) :: :ok | {:error, term()}
  def publish_branch(repo, branch, sha, git_env) do
    ref = "refs/heads/" <> branch

    case Refs.ref_read(repo, ref, git_env) do
      {:error, :missing} -> Refs.ref_create(repo, ref, sha, git_env)
      {:ok, ^sha} -> :ok
      {:ok, previous} -> Refs.ref_update(repo, ref, sha, previous, git_env)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ref_delete(Path.t(), String.t(), String.t(), git_env()) :: :ok | {:error, :stale | term()}
  def ref_delete(repo, ref, expected_sha, git_env),
    do: Refs.ref_delete(repo, ref, expected_sha, git_env)

  @spec commit_tree_with_files(
          Path.t(),
          %{String.t() => binary()},
          [String.t()],
          String.t(),
          git_env()
        ) :: {:ok, String.t()} | {:error, term()}
  def commit_tree_with_files(repo, files, parents, message, git_env),
    do: Refs.commit_tree_with_files(repo, files, parents, message, git_env)

  @spec read_file_at(Path.t(), String.t(), String.t(), git_env()) ::
          {:ok, binary()} | {:error, :missing | term()}
  def read_file_at(repo, rev, path, git_env), do: Refs.read_file_at(repo, rev, path, git_env)

  @spec write_file(Path.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(root, path, bytes), do: ApprovedFile.write(root, path, bytes)

  @spec tree_paths(Path.t(), String.t(), git_env()) :: {:ok, [String.t()]} | {:error, term()}
  def tree_paths(repo, rev, git_env), do: Refs.tree_paths(repo, rev, git_env)

  @spec commit_message(Path.t(), String.t(), git_env()) :: {:ok, binary()} | {:error, term()}
  def commit_message(repo, rev, git_env), do: Refs.commit_message(repo, rev, git_env)

  @spec rev_parse(Path.t(), String.t(), git_env()) ::
          {:ok, String.t()} | {:error, :missing | term()}
  def rev_parse(repo, rev, git_env), do: Refs.rev_parse(repo, rev, git_env)

  @spec intent_commit(Path.t(), String.t(), String.t(), git_env()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def intent_commit(repo, branch, slug, git_env) do
    ref = if String.starts_with?(branch, "refs/heads/"), do: branch, else: "refs/heads/" <> branch

    case Refs.rev_parse(repo, ref, git_env) do
      {:ok, branch_sha} -> Refs.intent_commit(repo, branch_sha, slug, git_env)
      {:error, :missing} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ancestor?(Path.t(), String.t(), String.t(), git_env()) :: boolean() | {:error, term()}
  def ancestor?(repo, a, b, git_env), do: Refs.ancestor?(repo, a, b, git_env)
end

defmodule Kogen.Workspace.Process do
  @moduledoc false

  alias Kogen.Contracts.ProcResult

  @spec run([String.t()], keyword()) :: {:ok, ProcResult.t()} | {:error, term()}
  def run(argv, options), do: Kogen.Proc.run(argv, options)
end
