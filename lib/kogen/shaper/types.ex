defmodule Kogen.Shaper.Request do
  @moduledoc false

  @default_limits %{max_turns: 60, wall_ms: 1_800_000}

  @enforce_keys [
    :workdir,
    :slug,
    :task,
    :model,
    :effort,
    :provider_mod,
    :provider_config,
    :env,
    :git_env,
    :run_dir
  ]
  defstruct @enforce_keys ++ [sandbox: nil, limits: @default_limits]

  @type limits :: %{max_turns: pos_integer(), wall_ms: pos_integer()}

  @type t :: %__MODULE__{
          workdir: Path.t(),
          slug: String.t(),
          task: String.t(),
          model: String.t(),
          effort: String.t(),
          provider_mod: module(),
          provider_config: term(),
          env: %{String.t() => String.t()},
          git_env: %{String.t() => String.t()},
          run_dir: Path.t(),
          sandbox: Kogen.Proc.Sandbox.t() | nil,
          limits: limits()
        }
end

defmodule Kogen.Shaper.Result do
  @moduledoc false

  @enforce_keys [
    :slug,
    :intent_path,
    :acceptance_path,
    :calls,
    :rounds,
    :transcript_path,
    :warnings
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          slug: String.t(),
          intent_path: Path.t(),
          acceptance_path: Path.t(),
          calls: [Kogen.Harness.ShapeCall.t()],
          rounds: pos_integer(),
          transcript_path: Path.t(),
          warnings: [Kogen.Contracts.ShapeWarning.t()]
        }
end
