defmodule Kogen.Checks.RunState do
  @moduledoc false

  @enforce_keys [:workdir, :run_dir, :env, :tree, :sandbox]
  defstruct [
    :workdir,
    :run_dir,
    :env,
    :tree,
    :sandbox,
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
          tree: String.t(),
          index: pos_integer(),
          receipts: [Kogen.Contracts.Receipt.t()],
          failures: [String.t()],
          feedbacks: [map()]
        }
end
