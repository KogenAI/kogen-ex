defmodule Kogen.Tooling.Context do
  @moduledoc "Execution inputs shared by Builder tools without depending on Harness options."

  @enforce_keys [:workdir, :run_dir, :project, :proc_mod]
  defstruct [:workdir, :run_dir, :project, :proc_mod, :sandbox, env: %{}, protected: []]

  @type t :: %__MODULE__{
          workdir: Path.t(),
          run_dir: Path.t(),
          project: Kogen.Contracts.Project.t(),
          proc_mod: module(),
          sandbox: Kogen.Proc.Sandbox.t() | nil,
          env: %{String.t() => String.t()},
          protected: [String.t()]
        }
end
