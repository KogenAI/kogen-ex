defmodule Kogen.Checks.RunState do
  @moduledoc false

  @enforce_keys [:workdir, :run_dir, :env, :tree, :sandbox]
  defstruct [
    :workdir,
    :run_dir,
    :env,
    :tree,
    :git_env,
    :sandbox,
    baseline: [],
    baseline_run?: false,
    index: 1,
    receipts: [],
    failures: [],
    feedbacks: []
  ]

  @type t :: %__MODULE__{
          workdir: Path.t(),
          run_dir: Path.t(),
          env: %{String.t() => String.t()},
          sandbox: Kogen.Proc.Sandbox.t() | nil,
          baseline: [],
          baseline_run?: boolean(),
          tree: String.t(),
          git_env: map(),
          baseline: [map()],
          index: pos_integer(),
          receipts: [Kogen.Contracts.Receipt.t()],
          failures: [String.t()],
          feedbacks: [map()]
        }
end
