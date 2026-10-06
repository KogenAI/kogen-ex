defmodule Kogen.Engine.Build.GateSupport do
  @moduledoc false

  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Stack
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
    |> Map.put(:phase_recorder, opts.phase_recorder || phase_recorder(session))
    |> Map.put(:event_recorder, opts.event_recorder || event_recorder(session))
    |> Map.put(:request_tags, %{attempt: session.attempt, rung: rung_name(session)})
    |> Map.put(:protected_restorer, opts.protected_restorer || protected_restorer(session))
    |> Map.put(:changed?, opts.changed? || changed_detector(session))
    |> Map.put(:protected, Enum.uniq(opts.protected ++ protected))
    |> Map.put(:check_baseline, session.approval.check_baseline)
    |> Map.put(:base, session.base_sha)
    |> Map.put(:base_test, base_test)
    |> Map.put(:changed_paths, changed_paths)
    |> Map.put(:changed_ranges, fn ->
      Workspace.changed_line_ranges(session.workdir, session.base_sha, session.git_env)
    end)
    |> Map.put(:flake_excused_test_ids, previously_excused)
  end

  @spec builder_settings(Session.t()) :: {String.t(), String.t()}
  def builder_settings(%Session{rung: %{} = rung, request: %{recipe: recipe}}),
    do: Recipe.rung_builder(recipe, rung)

  def builder_settings(%Session{attempt: :escalation, request: %{recipe: recipe}}) do
    case Recipe.escalation(recipe) do
      %{model: model, effort: effort} -> {model, effort}
      _missing -> Recipe.role(recipe, :builder)
    end
  end

  def builder_settings(%Session{request: %{recipe: recipe}}), do: Recipe.role(recipe, :builder)

  @spec resume_data(Session.t(), map()) :: map() | nil
  def resume_data(%Session{rung: %{}}, %{escalation_summary: summary}) when is_binary(summary),
    do: %{previous_items: [], failure_text: summary, fresh: true}

  def resume_data(%Session{last_harness: %HarnessResult{items: items}, failure_text: text}, %{
        landing: true
      }), do: %{previous_items: items, failure_text: text}

  def resume_data(%Session{attempt: :escalation}, args) do
    %{
      previous_items: [],
      failure_text: Map.get(args, :escalation_summary, "Builder attempt failed."),
      fresh: true
    }
  end

  def resume_data(%Session{last_harness: %HarnessResult{items: items}, failure_text: text}, _args)
      when is_binary(text), do: %{previous_items: items, failure_text: text}

  def resume_data(_session, _args), do: nil

  @doc """
  The Developer's task text: the approved Intent, or for a raw-request rung only the verbatim
  Request, optionally the Intent's Acceptance items, and the acceptance tests it must pass.
  """
  @spec builder_text(Session.t()) :: String.t()
  def builder_text(%Session{rung: %{input: :raw_request} = rung} = session) do
    slug = session.approval.slug

    source =
      Map.get(
        session.approval.acceptance_files,
        Stack.acceptance_source(session.project.root, slug),
        ""
      )

    String.trim("""
    ## Request
    #{session.intent.request || session.intent_text}
    #{acceptance_items(rung, session.intent.acceptance)}
    ## Acceptance tests
    These read-only tests are installed at #{Stack.acceptance_test(session.project.root, slug)} and must pass.

    ```#{if Stack.detect(session.project.root) == :rails, do: "ruby", else: "elixir"}
    #{String.trim_trailing(source)}
    ```
    """)
  end

  def builder_text(%Session{} = session), do: session.intent_text

  defp acceptance_items(%{acceptance_items: true}, [_ | _] = items),
    do: "\n## Acceptance\n" <> Enum.map_join(items, "\n", &"- #{&1.id}: #{&1.text}") <> "\n"

  defp acceptance_items(_rung, _items), do: ""

  defp rung_name(%Session{rung: %{name: name}}), do: name
  defp rung_name(%Session{}), do: nil

  defp phase_recorder(session) do
    fn phase, name, wall_ms, started_at, finished_at ->
      State.record_phase_timing(session.run, phase, name, wall_ms, started_at, finished_at)
    end
  end

  defp event_recorder(session) do
    fn event -> State.record(session.run, Map.put(event, :attempt, session.attempt)) end
  end

  defp protected_restorer(session), do: fn -> restore_protected(session) end

  @spec restore_protected(Session.t()) :: {:ok, [String.t()]} | {:error, term()}
  def restore_protected(%Session{approval: approval} = session) do
    Workspace.restore_protected(%{
      workdir: session.workdir,
      origin: session.request.origin,
      base_sha: session.base_sha,
      slug: approval.slug,
      intent_bytes: approval.intent_bytes,
      acceptance_files: approval.acceptance_files,
      manifest: approval.protected_manifest,
      git_env: session.git_env
    })
  end

  @spec base_test(Session.t(), [String.t()], pos_integer()) ::
          {:ok, ProcResult.t()} | {:error, term()}
  def base_test(%Session{} = session, argv, timeout_ms) do
    State.measure_phase(session.run, "build", "gate_base_check", fn ->
      run_base_test(session, argv, timeout_ms)
    end)
  end

  defp run_base_test(%Session{} = session, argv, timeout_ms) do
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
        result = run_base_command(session, path, argv, timeout_ms, "flake-base")
        cleanup = Workspace.destroy(path)
        base_test_result(result, cleanup)

      {:error, reason} ->
        {:error, {:base_checkout_failed, reason}}
    end
  end

  @doc """
  Runs `argv` with the gate's sandbox and environment in a scratch copy of the Candidate's
  checkout with `files` added. The copy is removed afterwards; `name` labels it and its log.
  """
  @spec scratch_test(Session.t(), map(), [String.t()], pos_integer(), String.t()) ::
          {:ok, ProcResult.t()} | {:error, term()}
  def scratch_test(%Session{} = session, files, argv, timeout_ms, name \\ "cross-check") do
    id = "#{session.run.id}-#{System.unique_integer([:positive, :monotonic])}"
    path = Path.join([session.request.home, ".kogen", "workspaces", name, id])

    result =
      with :ok <- Workspace.copy_on_write(session.workdir, path),
           :ok <- Workspace.insert_files(path, files) do
        run_base_command(session, path, argv, timeout_ms, name)
      end

    base_test_result(result, Workspace.destroy(path))
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

  # A raw Intent without Acceptance items has no acceptance tests; its gate is the project's
  # checks.
  @spec red_on_base(Session.t()) :: :ok | {:error, Failure.t()}
  def red_on_base(%Session{intent: %{source: :raw, acceptance: []}}), do: :ok

  def red_on_base(%Session{} = session) do
    State.measure_phase(session.run, "build", "red-on-base", fn ->
      Kogen.Checks.red_on_base(
        session.workdir,
        session.intent,
        session.run_dir,
        session.process_env,
        session.git_env,
        session.sandbox
      )
    end)
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
    |> Enum.reduce_while({:ok, []}, fn flake, {:ok, recorded} ->
      case State.record(session.run, Map.put(flake, :event, :flake_excused)) do
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

  defdelegate gate_failure(result), to: Failure, as: :from_developer

  defp default_harness_options(session, guard) do
    context = Map.get(session.request.recipe.roles, :context)
    builder = builder_settings(session)
    planner = Map.get(session.request.recipe.roles, :planner, {"gpt-6.1-sol", "high"})
    reviewer = Map.get(session.request.recipe.roles, :reviewer, builder)
    recipe = session.request.recipe

    %Opts{
      workdir: session.workdir,
      run_dir: session.run_dir,
      project: session.project,
      sandbox: session.sandbox,
      provider_mod: session.request.provider_mod,
      provider_config: session.request.provider_config,
      resilience: Recipe.resilience(recipe, session.request.resilience),
      proc_mod: Kogen.Proc,
      env: session.process_env,
      before_gate: guard,
      models: %{
        builder: builder,
        strong: planner,
        context: context || {"gpt-6-luna", "low"},
        planner: planner,
        reviewer: reviewer,
        auditor: Recipe.auditor(recipe) || planner
      },
      limits: %{max_turns: 60, wall_ms: wall_ms(session)},
      repairs_left: 0,
      builder_tools: recipe.builder_tools,
      planner_mode:
        if(Recipe.name(recipe) == "plan-shell" or Recipe.ladder(recipe) != nil,
          do: :ls_files,
          else: :read_only_tools
        ),
      planner_difficulty: Recipe.ladder(recipe) != nil
    }
  end

  # A ladder's whole-Build budget also bounds each stage.
  defp wall_ms(%Session{landing_deadline: deadline}) when is_integer(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 1)

  defp wall_ms(session) do
    [session.budget_deadline, session.landing_deadline]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(1_800_000, fn deadline, cap ->
      min(cap, max(deadline - System.monotonic_time(:millisecond), 1))
    end)
  end

  defp changed_detector(session) do
    fn ->
      case Workspace.changed_paths(session.workdir, session.base_sha, session.git_env) do
        {:ok, paths} -> {:ok, paths != []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp run_base_command(session, path, argv, timeout_ms, log_name) do
    log_path =
      Path.join([
        session.run_dir,
        "logs",
        "#{log_name}-#{System.unique_integer([:positive, :monotonic])}.log"
      ])

    with :ok <- File.mkdir_p(Path.dirname(log_path)) do
      sandbox =
        case session.sandbox do
          %Kogen.Proc.Sandbox{} = value -> %{value | workspace: path}
          nil -> nil
        end

      argv
      |> Kogen.Proc.run(
        cd: path,
        env:
          Kogen.Engine.RailsEnvironment.apply(session.process_env, path, %{
            session.project
            | root: path
          }),
        timeout_ms: timeout_ms,
        log_path: log_path,
        sandbox: sandbox
      )
      |> Kogen.Checks.Timing.process(session.run_dir, log_name, argv)
    end
  end

  defp base_test_result({:ok, result}, :ok), do: {:ok, result}
  defp base_test_result({:error, reason}, :ok), do: {:error, reason}
  defp base_test_result(_result, {:error, reason}), do: {:error, {:base_checkout_cleanup, reason}}
end
