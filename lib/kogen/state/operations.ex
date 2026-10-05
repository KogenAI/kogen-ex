defmodule Kogen.State.Operations do
  @moduledoc false

  alias Kogen.State.Approval
  alias Kogen.State.ApprovalStore
  alias Kogen.State.Lifecycle
  alias Kogen.State.Run
  alias Kogen.State.RunStore

  @workspace_module :"Elixir.Kogen.Workspace"

  @spec approve(term(), Approval.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def approve(repo, approval, git_env, options \\ []) do
    with {:ok, workspace} <- workspace(options) do
      ApprovalStore.approve(repo, approval, git_env, workspace)
    end
  end

  @spec approval(term(), String.t(), map(), keyword()) ::
          {:ok, Approval.t()} | {:error, term()}
  def approval(repo, slug, git_env, options \\ []) do
    with {:ok, workspace} <- workspace(options) do
      ApprovalStore.read(repo, slug, git_env, workspace)
    end
  end

  @spec claim(term(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def claim(repo, run_id, git_env, options \\ []) do
    with {:ok, workspace} <- workspace(options) do
      Lifecycle.claim(repo, run_id, git_env, workspace)
    end
  end

  @spec release(term(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def release(repo, run_id, git_env, options \\ []) do
    with {:ok, workspace} <- workspace(options) do
      Lifecycle.release(repo, run_id, git_env, workspace)
    end
  end

  @spec start_run(Path.t(), Approval.t()) :: {:ok, Run.t()} | {:error, term()}
  def start_run(root, approval), do: RunStore.start_run(root, approval)

  @spec record(Run.t(), map()) :: :ok | {:error, term()}
  def record(run, event), do: RunStore.record(run, event)

  @spec put_landing(Run.t(), map()) :: :ok | {:error, term()}
  def put_landing(run, identity), do: RunStore.put_landing(run, identity)

  @spec load(Path.t(), String.t()) :: {:ok, Run.t()} | {:error, term()}
  def load(root, run_id), do: RunStore.load(root, run_id)

  @spec list(Path.t()) :: {:ok, [Run.t()]} | {:error, term()}
  def list(root), do: RunStore.list(root)

  @spec status(term(), Path.t(), String.t(), String.t(), map(), keyword()) :: Kogen.State.status()
  def status(repo, root, slug, branch, git_env, options \\ []) do
    case workspace(options) do
      {:ok, workspace} ->
        Lifecycle.status(repo, root, slug, branch, git_env, workspace)

      {:error, reason} ->
        raise ArgumentError, "invalid State workspace option: #{inspect(reason)}"
    end
  end

  @spec reconcile(term(), Path.t(), Run.t(), String.t(), map(), keyword()) ::
          {:ok, :landed | :unchanged} | {:error, term()}
  def reconcile(repo, root, run, branch, git_env, options \\ []) do
    with {:ok, workspace} <- workspace(options) do
      Lifecycle.reconcile(repo, root, run, branch, git_env, workspace)
    end
  end

  @spec recover_crashed(term(), Path.t(), Run.t(), map(), keyword()) :: :ok | {:error, term()}
  def recover_crashed(repo, root, run, git_env, options \\ []) do
    with {:ok, workspace} <- workspace(options),
         {:ok, reason} <- crash_reason(options) do
      Lifecycle.recover_crashed(repo, root, run, git_env, workspace, reason)
    end
  end

  # A Build whose owner died after recording a SIGTERM ended as `interrupted`, not `crashed`.
  defp crash_reason(options) do
    case Keyword.get(options, :reason, :crashed) do
      reason when reason in [:crashed, :interrupted] -> {:ok, reason}
      _other -> {:error, :invalid_options}
    end
  end

  defp workspace(options) when is_list(options) do
    case Keyword.keyword?(options) and Keyword.get(options, :workspace, @workspace_module) do
      true ->
        {:ok, @workspace_module}

      false ->
        {:error, :invalid_options}

      workspace when is_atom(workspace) and workspace not in [nil, true, false] ->
        {:ok, workspace}

      _other ->
        {:error, :invalid_workspace}
    end
  end

  defp workspace(_options), do: {:error, :invalid_options}
end
