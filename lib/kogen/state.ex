defmodule Kogen.State do
  @moduledoc "Persists run records and coordinates Git-derived Build state."

  use Boundary,
    deps: [Kogen.Contracts, Kogen.Workspace],
    exports: [Approval, Event, Run]

  alias Kogen.State.Approval
  alias Kogen.State.Event
  alias Kogen.State.Json
  alias Kogen.State.Operations
  alias Kogen.State.PhaseTiming
  alias Kogen.State.RequestUsage
  alias Kogen.State.Run
  alias Kogen.State.Usage

  @type status :: :draft | :approved | :building | :interrupted | :landed | :failed | :parked

  @spec approve(Path.t(), Approval.t(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, term()}
  @spec approve(Path.t(), Approval.t(), %{String.t() => String.t()}, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate approve(repo, approval, git_env, options \\ []), to: Operations

  @spec approval(Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, Approval.t()} | {:error, term()}
  @spec approval(Path.t(), String.t(), %{String.t() => String.t()}, keyword()) ::
          {:ok, Approval.t()} | {:error, term()}
  defdelegate approval(repo, slug, git_env, options \\ []), to: Operations

  @spec claim(Path.t(), String.t(), %{String.t() => String.t()}) :: :ok | {:error, term()}
  @spec claim(Path.t(), String.t(), %{String.t() => String.t()}, keyword()) ::
          :ok | {:error, term()}
  defdelegate claim(repo, run_id, git_env, options \\ []), to: Operations

  @spec release(Path.t(), String.t(), %{String.t() => String.t()}) :: :ok | {:error, term()}
  @spec release(Path.t(), String.t(), %{String.t() => String.t()}, keyword()) ::
          :ok | {:error, term()}
  defdelegate release(repo, run_id, git_env, options \\ []), to: Operations

  @spec start_run(Path.t(), Approval.t()) :: {:ok, Run.t()} | {:error, term()}
  defdelegate start_run(root, approval), to: Operations

  @spec record(Run.t(), map()) :: :ok | {:error, term()}
  defdelegate record(run, event), to: Operations

  @doc "Measures an operation and records its phase timing, including when it raises."
  @spec measure_phase(Run.t(), String.t(), String.t(), (-> result)) :: result when result: term()
  defdelegate measure_phase(run, phase, name, operation), to: PhaseTiming, as: :measure

  @spec record_phase_timing(
          Run.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          integer(),
          integer()
        ) :: :ok | {:error, term()}
  defdelegate record_phase_timing(run, phase, name, wall_ms, started_at, finished_at),
    to: PhaseTiming,
    as: :record

  @spec decode_event(binary()) :: {:ok, Event.t()} | {:error, :invalid_event}
  defdelegate decode_event(binary), to: Json

  @spec attempt_usage(Run.t(), term()) ::
          {:ok, %{tokens: map(), model_wall_ms: non_neg_integer()}} | {:error, term()}
  defdelegate attempt_usage(run, attempt), to: Usage, as: :attempt

  @doc "Usage the request journal saw that no finished stage recorded, as `model_stage` events."
  @spec unfinished_usage(Run.t(), [Event.t()]) :: {:ok, [Event.t()]} | {:error, term()}
  defdelegate unfinished_usage(run, events), to: RequestUsage, as: :unfinished

  @spec put_landing(Run.t(), map()) :: :ok | {:error, term()}
  defdelegate put_landing(run, identity), to: Operations

  @spec load(Path.t(), String.t()) :: {:ok, Run.t()} | {:error, term()}
  defdelegate load(root, run_id), to: Operations

  @spec list(Path.t()) :: {:ok, [Run.t()]} | {:error, term()}
  defdelegate list(root), to: Operations

  @spec status(Path.t(), Path.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          status()
  @spec status(
          Path.t(),
          Path.t(),
          String.t(),
          String.t(),
          %{String.t() => String.t()},
          keyword()
        ) :: status()
  defdelegate status(repo, root, slug, branch, git_env, options \\ []), to: Operations

  @spec reconcile(Path.t(), Path.t(), Run.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, :landed | :unchanged} | {:error, term()}
  @spec reconcile(
          Path.t(),
          Path.t(),
          Run.t(),
          String.t(),
          %{String.t() => String.t()},
          keyword()
        ) :: {:ok, :landed | :unchanged} | {:error, term()}
  defdelegate reconcile(repo, root, run, branch, git_env, options \\ []), to: Operations

  @spec recover_crashed(Path.t(), Path.t(), Run.t(), %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  @spec recover_crashed(
          Path.t(),
          Path.t(),
          Run.t(),
          %{String.t() => String.t()},
          keyword()
        ) :: :ok | {:error, term()}
  defdelegate recover_crashed(repo, root, run, git_env, options \\ []), to: Operations
end
