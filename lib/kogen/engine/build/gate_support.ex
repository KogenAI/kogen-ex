defmodule Kogen.Engine.Build.GateSupport do
  @moduledoc false

  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Engine.Build.Guard
  alias Kogen.Engine.Build.Session
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Result, as: HarnessResult
  alias Kogen.State
  alias Kogen.Workspace

  @spec harness_options(Session.t()) :: Opts.t()
  def harness_options(%Session{} = session) do
    guard = fn ->
      Guard.check(
        session.workdir,
        session.base_sha,
        session.intent,
        session.project,
        session.approval.protected_manifest,
        session.git_env
      )
    end

    opts = session.harness_opts || default_harness_options(session, guard)
    protected = Map.keys(session.approval.protected_manifest)
    base_test = fn argv, timeout_ms -> base_test(session, argv, timeout_ms) end

    changed_paths = fn ->
      Workspace.changed_paths(session.workdir, session.base_sha, session.git_env)
    end

    previously_excused = Enum.flat_map(session.flake_excused, & &1.test_ids)

    opts
    |> Map.put(:changed?, opts.changed? || changed_detector(session))
    |> Map.put(:protected, Enum.uniq(opts.protected ++ protected))
    |> Map.put(:base_test, base_test)
    |> Map.put(:changed_paths, changed_paths)
    |> Map.put(:flake_excused_test_ids, previously_excused)
  end

  @spec base_test(Session.t(), [String.t()], pos_integer()) ::
          {:ok, ProcResult.t()} | {:error, term()}
  def base_test(%Session{} = session, argv, timeout_ms) do
    build_id = "flake-#{session.run.id}-#{System.unique_integer([:positive, :monotonic])}"
    root = Path.join([session.request.home, ".kogen", "workspaces", "flake-probes"])

    case Workspace.create(
           session.request.origin,
           session.base_sha,
           root,
           build_id,
           session.git_env,
           seed_from: session.request.project_root
         ) do
      {:ok, %{path: path}} ->
        result = run_base_command(session, path, argv, timeout_ms)
        cleanup = Workspace.destroy(path)
        base_test_result(result, cleanup)

      {:error, reason} ->
        {:error, {:base_checkout_failed, reason}}
    end
  end

  @spec scope_warnings(Session.t()) :: {:ok, [map()]} | {:error, Failure.t()}
  def scope_warnings(%Session{} = session) do
    Guard.scope_warnings(
      session.workdir,
      session.base_sha,
      session.intent,
      session.project,
      session.git_env
    )
  end

  @spec record_scope_warnings(Session.t(), [map()]) :: :ok | {:error, term()}
  def record_scope_warnings(%Session{} = session, warnings) do
    Enum.reduce_while(warnings, :ok, fn warning, :ok ->
      case State.record(session.run, %{
             event: :scope_warning,
             path: warning.path,
             declared_domains: warning.declared_domains,
             detail: warning.finding
           }) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec record_gate_flakes(Session.t(), map() | nil) ::
          {:ok, [map()]} | {:error, Failure.t()}
  def record_gate_flakes(%Session{} = session, gate) when is_map(gate) do
    gate
    |> Map.get(:flake_excused, [])
    |> Enum.reduce_while({:ok, []}, fn %{test_ids: test_ids, seed: seed} = flake,
                                       {:ok, recorded} ->
      case State.record(session.run, %{event: :flake_excused, test_ids: test_ids, seed: seed}) do
        :ok -> {:cont, {:ok, [flake | recorded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, recorded} ->
        {:ok, Enum.reverse(recorded)}

      {:error, reason} ->
        {:error,
         %Failure{class: :controller, reason: :state_write_failed, detail: inspect(reason)}}
    end
  end

  def record_gate_flakes(_session, _gate), do: {:ok, []}

  def gate_failure(%HarnessResult{outcome: :done}), do: {nil, nil}

  def gate_failure(%HarnessResult{outcome: :gate_environment, gate: gate}) do
    detail = gate_detail(gate, "The done gate could not complete its checks.")
    {%Failure{class: :environment, reason: :check_unavailable, detail: detail}, detail}
  end

  def gate_failure(%HarnessResult{outcome: :gave_up}) do
    detail = "Developer exhausted its turn or wall limit."
    {%Failure{class: :candidate, reason: :developer_gave_up, detail: detail}, detail}
  end

  def gate_failure(%HarnessResult{outcome: :gate_red, gate: gate}) do
    detail = gate_detail(gate, "Harness done gate failed.")
    {%Failure{class: :candidate, reason: :done_gate_red, detail: detail}, detail}
  end

  defp gate_detail(%{failures: failures}, fallback) when is_list(failures),
    do: if(failures == [], do: fallback, else: Enum.join(failures, "\n"))

  defp gate_detail(_gate, fallback), do: fallback

  defp default_harness_options(session, guard) do
    context = Map.get(session.request.recipe.roles, :context)
    builder = Recipe.role(session.request.recipe, :builder)
    planner = Map.get(session.request.recipe.roles, :planner, builder)
    reviewer = Map.get(session.request.recipe.roles, :reviewer, builder)

    %Opts{
      workdir: session.workdir,
      run_dir: session.run_dir,
      project: session.project,
      sandbox: session.sandbox,
      provider_mod: session.request.provider_mod,
      provider_config: session.request.provider_config,
      proc_mod: Kogen.Proc,
      env: session.process_env,
      before_gate: guard,
      models: %{
        builder: builder,
        strong: planner,
        context: context || {"gpt-6-luna", "low"},
        planner: planner,
        reviewer: reviewer
      },
      limits: %{max_turns: 60, wall_ms: 1_800_000},
      repairs_left: 0
    }
  end

  defp changed_detector(session) do
    fn ->
      case Workspace.changed_paths(session.workdir, session.base_sha, session.git_env) do
        {:ok, paths} -> {:ok, paths != []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp run_base_command(session, path, argv, timeout_ms) do
    log_path =
      Path.join([
        session.run_dir,
        "logs",
        "flake-base-#{System.unique_integer([:positive, :monotonic])}.log"
      ])

    with :ok <- File.mkdir_p(Path.dirname(log_path)) do
      sandbox =
        case session.sandbox do
          %Kogen.Proc.Sandbox{} = value -> %{value | workspace: path}
          nil -> nil
        end

      Kogen.Proc.run(argv,
        cd: path,
        env: session.process_env,
        timeout_ms: timeout_ms,
        log_path: log_path,
        sandbox: sandbox
      )
    end
  end

  defp base_test_result({:ok, result}, :ok), do: {:ok, result}
  defp base_test_result({:error, reason}, :ok), do: {:error, reason}
  defp base_test_result(_result, {:error, reason}), do: {:error, {:base_checkout_cleanup, reason}}
end
