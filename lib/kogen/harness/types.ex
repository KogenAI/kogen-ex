defmodule Kogen.Harness.Opts do
  @moduledoc "Explicit runtime inputs for one Harness pipeline."

  @enforce_keys [:workdir, :run_dir, :project, :provider_mod, :provider_config, :proc_mod]
  defstruct [
    :workdir,
    :run_dir,
    :project,
    :sandbox,
    :provider_mod,
    :provider_config,
    :proc_mod,
    :base_test,
    :changed_paths,
    :phase_recorder,
    :event_recorder,
    :protected_restorer,
    builder_tools: :full,
    planner_mode: :read_only_tools,
    changed?: nil,
    env: %{},
    before_gate: nil,
    check_baseline: [],
    flake_excused_test_ids: [],
    models: %{builder: {"gpt-6-luna", "max"}, strong: {"gpt-6.1-sol", "high"}},
    limits: %{max_turns: 60, wall_ms: 1_800_000},
    repairs_left: 2,
    protected: []
  ]

  @type model :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          workdir: Path.t(),
          run_dir: Path.t(),
          project: Kogen.Contracts.Project.t(),
          sandbox: Kogen.Proc.Sandbox.t() | nil,
          provider_mod: module(),
          provider_config: term(),
          proc_mod: module(),
          base_test: function() | nil,
          check_baseline: [map()],
          changed_paths: function() | nil,
          phase_recorder: function() | nil,
          event_recorder: (map() -> :ok | {:error, term()}) | nil,
          protected_restorer: (-> {:ok, [String.t()]} | {:error, term()}) | nil,
          changed?: (-> {:ok, boolean()} | {:error, term()}) | nil,
          env: %{String.t() => String.t()},
          before_gate: (-> :ok | {:error, term()}) | nil,
          flake_excused_test_ids: [String.t()],
          builder_tools: :full | :shell,
          planner_mode: :read_only_tools | :ls_files,
          models: %{
            required(:builder) => model(),
            required(:strong) => model(),
            optional(:context) => model(),
            optional(:planner) => model(),
            optional(:reviewer) => model()
          },
          limits: %{max_turns: pos_integer(), wall_ms: pos_integer() | :infinity},
          repairs_left: non_neg_integer(),
          protected: [String.t()]
        }
end

defmodule Kogen.Harness.Pack do
  @moduledoc "Read-only context collected for a single Intent."

  @enforce_keys [:text, :refs, :usage, :files, :snippets]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          text: String.t(),
          refs: [String.t()],
          usage: map(),
          files: [Path.t()],
          snippets: [String.t()]
        }
end

defmodule Kogen.Harness.Plan do
  @moduledoc "One strong-model implementation plan, scoped to its Intent."

  @enforce_keys [:text, :usage]
  defstruct @enforce_keys ++ [builder_addendum: nil]

  @type t :: %__MODULE__{text: String.t(), usage: map(), builder_addendum: String.t() | nil}
end

defmodule Kogen.Harness.Review do
  @moduledoc "One advisory review result."

  @enforce_keys [:verdict, :findings, :usage]
  defstruct @enforce_keys

  @type verdict :: :accept | :revise
  @type t :: %__MODULE__{verdict: verdict(), findings: [String.t()], usage: map()}
end

defmodule Kogen.Harness.Result do
  @moduledoc "Outcome of one Developer pass and its single in-session gate."

  @enforce_keys [:outcome, :gate, :items, :turns, :usage, :transcript_path]
  defstruct @enforce_keys

  @type outcome :: :done | :gate_red | :gate_environment | :turn_cap | :wall_cap
  @type t :: %__MODULE__{
          outcome: outcome(),
          gate: map() | nil,
          items: list(),
          turns: non_neg_integer(),
          usage: map(),
          transcript_path: Path.t()
        }
end

defmodule Kogen.Harness.Usage do
  @moduledoc false

  @enforce_keys [:input, :cached_input, :cache_write, :output, :reasoning]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          input: non_neg_integer(),
          cached_input: non_neg_integer(),
          cache_write: non_neg_integer(),
          output: non_neg_integer(),
          reasoning: non_neg_integer()
        }

  @spec zero() :: t()
  def zero, do: %__MODULE__{input: 0, cached_input: 0, cache_write: 0, output: 0, reasoning: 0}

  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = left, %__MODULE__{} = right) do
    %__MODULE__{
      input: left.input + right.input,
      cached_input: left.cached_input + right.cached_input,
      cache_write: left.cache_write + right.cache_write,
      output: left.output + right.output,
      reasoning: left.reasoning + right.reasoning
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = usage), do: Map.from_struct(usage)
end

defmodule Kogen.Harness.ShapeCall do
  @moduledoc false

  @enforce_keys [:stage, :model, :effort, :tokens, :wall_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          stage: :shape,
          model: String.t(),
          effort: String.t(),
          tokens: %{optional(atom()) => non_neg_integer()},
          wall_ms: non_neg_integer()
        }
end

defmodule Kogen.Harness.ShapePass do
  @moduledoc false

  @enforce_keys [:items, :text, :calls, :turns, :written_paths]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          items: [map()],
          text: String.t(),
          calls: [Kogen.Harness.ShapeCall.t()],
          turns: non_neg_integer(),
          written_paths: [Path.t()]
        }
end

defmodule Kogen.Harness.GateCommand do
  @moduledoc false

  @enforce_keys [:name, :exit_status, :timed_out, :output]
  defstruct @enforce_keys ++
              [
                :log_path,
                base_red?: false,
                reason: nil,
                tool: "check",
                exit_level: 3,
                findings: [],
                dialyzer_summaries: []
              ]

  @type t :: %__MODULE__{
          name: String.t(),
          exit_status: integer() | nil,
          timed_out: boolean(),
          output: String.t(),
          log_path: Path.t() | nil,
          base_red?: boolean(),
          reason: String.t() | nil,
          tool: String.t(),
          exit_level: 0..3,
          findings: [map()],
          dialyzer_summaries: [String.t()]
        }
end

defmodule Kogen.Harness.GateResult do
  @moduledoc false

  alias Kogen.Harness.GateCommand

  @enforce_keys [:status, :fixes, :checks, :failures, :flake_excused, :failed_test_count]
  defstruct @enforce_keys ++ [warnings: []]

  @type t :: %__MODULE__{
          status: :pass | :fail | :environment,
          fixes: [GateCommand.t()],
          checks: [GateCommand.t()],
          failures: [String.t()],
          warnings: [String.t()],
          flake_excused: [%{test_ids: [String.t()], seed: non_neg_integer()}],
          failed_test_count: non_neg_integer() | nil
        }
end

defmodule Kogen.Harness.TranscriptEntry do
  @moduledoc false

  @enforce_keys [:event, :stage, :turn, :payload]
  defstruct @enforce_keys

  @type t :: %__MODULE__{event: atom(), stage: atom(), turn: non_neg_integer(), payload: term()}
end
