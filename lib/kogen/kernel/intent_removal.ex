defmodule Kogen.Kernel.IntentRemoval do
  @moduledoc false

  alias Kogen.Contracts.Stack
  alias Kogen.Engine.Runtime
  alias Kogen.Kernel.ProjectContext
  alias Kogen.Kernel.Workspaces
  alias Kogen.Queue.IntentStatus
  alias Kogen.Queue.Status
  alias Kogen.Workspace

  @spec run(String.t(), Path.t(), Path.t() | nil, String.t() | nil, boolean()) ::
          {:ok, String.t()} | {:error, term()}
  def run(slug, project_root, origin_override, base_override, force) do
    with :ok <- valid_slug(slug),
         {:ok, runtime} <- Kogen.Kernel.runtime(),
         {:ok, home} <- runtime_home(runtime),
         {:ok, project} <- Kogen.Project.load(project_root),
         {:ok, process_env} <- Kogen.Kernel.project_environment(project_root, runtime),
         git_env = Runtime.git_environment(process_env),
         {:ok, origin, base} <-
           ProjectContext.resolve(project_root, project, origin_override, base_override, git_env),
         {:ok, statuses} <-
           Status.list(project_root, Workspaces.root(project_root, home), origin, base, git_env),
         %IntentStatus{} = status <- Enum.find(statuses, &(&1.slug == slug)) do
      remove(slug, project_root, origin, status, force, git_env)
    else
      nil -> {:error, :intent_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp runtime_home(runtime) do
    case Runtime.home(runtime) do
      home when is_binary(home) -> {:ok, home}
      nil -> Kogen.Kernel.RuntimeDiscovery.home()
    end
  end

  @doc false
  @spec remove(String.t(), Path.t(), Path.t(), IntentStatus.t(), boolean(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def remove(slug, project_root, origin, %IntentStatus{} = status, force, git_env) do
    if status.slug == slug do
      remove_files(slug, project_root, origin, status, force, git_env)
    else
      {:error, :intent_status_mismatch}
    end
  end

  defp remove_files(slug, project_root, origin, status, force, git_env) do
    intent_directory = Path.join([project_root, ".kogen", "intents", slug])
    intent_file = Path.join(intent_directory, "intent.md")
    acceptance_file = Path.join(project_root, Stack.acceptance_source(project_root, slug))
    intent_pathspec = ".kogen/intents/#{slug}"
    acceptance_pathspec = Stack.acceptance_source(project_root, slug)

    with :ok <- intent_exists(intent_file),
         :ok <- not_building(status),
         {:ok, approval_sha} <- approval_ref(origin, slug, git_env),
         :ok <- force_required(status, approval_sha, force),
         {:ok, intent_paths} <- Workspace.tracked_paths(project_root, intent_pathspec, git_env),
         {:ok, acceptance_paths} <-
           Workspace.tracked_paths(project_root, acceptance_pathspec, git_env),
         :ok <- require_tracked_intent(intent_paths),
         :ok <- remove_file_tree(intent_directory),
         :ok <- remove_file(acceptance_file),
         :ok <- remove_empty_directory(Path.dirname(intent_directory)),
         :ok <- remove_empty_directory(Path.dirname(acceptance_file)),
         {:ok, commit} <-
           Workspace.commit_paths(
             project_root,
             "Remove Intent #{slug}",
             intent_paths ++ acceptance_paths,
             [],
             git_env
           ),
         :ok <- remove_approval_ref(origin, slug, approval_sha, git_env) do
      {:ok, commit}
    end
  end

  defp valid_slug(slug) do
    if is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug),
      do: :ok,
      else: {:error, :invalid_slug}
  end

  defp intent_exists(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> :ok
      {:ok, _other} -> {:error, :intent_not_found}
      {:error, :enoent} -> {:error, :intent_not_found}
      {:error, reason} -> {:error, {:intent_unavailable, reason}}
    end
  end

  defp not_building(%IntentStatus{status: :building}), do: {:error, :intent_is_building}
  defp not_building(_status), do: :ok

  defp require_tracked_intent([]), do: {:error, :intent_must_be_tracked}
  defp require_tracked_intent(_paths), do: :ok

  defp remove_empty_directory(path) do
    case File.rmdir(path) do
      :ok -> :ok
      {:error, reason} when reason in [:eexist, :enoent] -> :ok
      {:error, reason} -> {:error, {:intent_remove_failed, path, reason}}
    end
  end

  defp approval_ref(origin, slug, git_env) do
    case Workspace.ref_read(origin, "refs/kogen/intents/#{slug}", git_env) do
      {:ok, sha} -> {:ok, sha}
      {:error, :missing} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp force_required(%IntentStatus{status: :landed}, _approval_sha, _force), do: :ok
  defp force_required(_status, nil, _force), do: :ok
  defp force_required(_status, _approval_sha, true), do: :ok

  defp force_required(%IntentStatus{status: status}, _approval_sha, false),
    do: {:error, {:intent_remove_requires_force, Atom.to_string(status)}}

  defp remove_file_tree(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, failed_path} -> {:error, {:intent_remove_failed, failed_path, reason}}
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:intent_remove_failed, path, reason}}
    end
  end

  defp remove_approval_ref(_origin, _slug, nil, _git_env), do: :ok

  defp remove_approval_ref(origin, slug, approval_sha, git_env) do
    case Workspace.ref_delete(origin, "refs/kogen/intents/#{slug}", approval_sha, git_env) do
      :ok -> :ok
      {:error, reason} -> {:error, {:approval_ref_remove_failed, reason}}
    end
  end
end
