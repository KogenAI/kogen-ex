defmodule Kogen.Engine.Build.Result do
  @moduledoc false

  @enforce_keys [:status, :reason, :failure, :run_id, :run_dir, :landed_sha, :lines]
  defstruct @enforce_keys ++ [verdict: :unknown]

  @type t :: %__MODULE__{
          status: :landed | :failed | :parked,
          reason: term(),
          failure: Kogen.Contracts.Failure.t() | nil,
          run_id: String.t(),
          run_dir: Path.t(),
          landed_sha: String.t() | nil,
          lines: [String.t()],
          verdict: :green | :red | :unknown
        }
end

defmodule Kogen.Engine.Build.Request do
  @moduledoc false

  alias Kogen.Resilience.Policy

  @enforce_keys [
    :slug,
    :home,
    :project_root,
    :workspace_root,
    :origin,
    :base,
    :model,
    :effort,
    :recipe,
    :runtime,
    :provider_mod,
    :provider_config,
    :credential_source,
    :credential_label
  ]
  defstruct @enforce_keys ++ [resilience: %Policy{}]

  @type t :: %__MODULE__{
          slug: String.t(),
          home: Path.t(),
          project_root: Path.t(),
          workspace_root: Path.t(),
          origin: Path.t(),
          base: String.t(),
          model: String.t(),
          effort: String.t(),
          recipe: Kogen.Build.Recipe.t(),
          runtime: Kogen.Engine.Runtime.t(),
          provider_mod: module(),
          provider_config: term(),
          credential_source: :kogen_owned | :custom,
          credential_label: String.t(),
          resilience: Policy.t()
        }
end

defmodule Kogen.Engine.Build.Prepared do
  @moduledoc false

  @enforce_keys [:request, :run, :approval, :approval_commit, :intent, :intent_text, :base_sha]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          request: Kogen.Engine.Build.Request.t(),
          run: Kogen.State.Run.t(),
          approval: Kogen.State.Approval.t(),
          approval_commit: String.t(),
          intent: Kogen.Contracts.Intent.t(),
          intent_text: String.t(),
          base_sha: String.t()
        }
end

defmodule Kogen.Engine.Build.Session do
  @moduledoc false

  @enforce_keys [
    :request,
    :approval,
    :approval_commit,
    :intent,
    :intent_text,
    :project,
    :run,
    :sandbox,
    :cycle,
    :state_root,
    :run_dir,
    :base_sha,
    :workdir,
    :process_env,
    :git_env
  ]
  defstruct [
    :request,
    :approval,
    :approval_commit,
    :intent,
    :intent_text,
    :project,
    :run,
    :sandbox,
    :cycle,
    :state_root,
    :run_dir,
    :base_sha,
    :workdir,
    :process_env,
    :git_env,
    :harness_opts,
    :pack,
    :plan,
    :last_harness,
    :failure,
    :failure_text,
    :landed_sha,
    :acceptance,
    :receipts,
    :verified_tree,
    :rung,
    :budget_deadline,
    :landing_deadline,
    :landing_verdict,
    :rung_started_at,
    :edge,
    direct_preflight_complete?: false,
    flake_excused: [],
    scope_warnings: [],
    lines: [],
    attempt: :builder,
    demoted: [],
    audited: %{},
    acceptance_failures: [],
    candidates: [],
    parallel_members: [],
    paused_ms: 0
  ]

  @type t :: %__MODULE__{
          request: Kogen.Engine.Build.Request.t(),
          approval: Kogen.State.Approval.t(),
          approval_commit: String.t(),
          intent: Kogen.Contracts.Intent.t(),
          intent_text: String.t(),
          project: Kogen.Contracts.Project.t(),
          run: Kogen.State.Run.t(),
          sandbox: Kogen.Proc.Sandbox.t(),
          cycle: struct(),
          state_root: Path.t(),
          run_dir: Path.t(),
          base_sha: String.t(),
          workdir: Path.t(),
          process_env: %{String.t() => String.t()},
          git_env: %{String.t() => String.t()},
          harness_opts: Kogen.Harness.Opts.t() | nil,
          pack: Kogen.Harness.Pack.t() | nil,
          plan: Kogen.Harness.Plan.t() | nil,
          last_harness: Kogen.Harness.Result.t() | nil,
          failure: Kogen.Contracts.Failure.t() | nil,
          failure_text: String.t() | nil,
          attempt: :builder | :escalation | String.t(),
          landed_sha: String.t() | nil,
          acceptance: [Kogen.Checks.LedgerRow.t()] | nil,
          receipts: [Kogen.Contracts.Receipt.t()] | nil,
          verified_tree: String.t() | nil,
          direct_preflight_complete?: boolean(),
          flake_excused: [%{test_ids: [String.t()], seed: non_neg_integer()}],
          scope_warnings: [map()],
          lines: [String.t()],
          rung: Kogen.Build.Recipe.rung() | nil,
          budget_deadline: integer() | nil,
          landing_deadline: integer() | nil,
          landing_verdict: :green | :red | nil,
          rung_started_at: integer() | nil,
          edge: map() | nil,
          demoted: [%{id: String.t(), reason: String.t()}],
          audited: %{String.t() => atom()},
          acceptance_failures: [String.t()],
          candidates: [map()],
          parallel_members: [t()],
          paused_ms: non_neg_integer()
        }
end
