defmodule Kogen.Contracts.Project do
  @moduledoc "A project's root, checks, acceptance checks, protected paths, gate config paths, and domain map."

  alias Kogen.Contracts.CheckSpec

  @enforce_keys [:root, :name, :checks, :setup, :fix, :diagnose, :protected_paths, :domains]
  defstruct @enforce_keys ++
              [
                format: nil,
                gate_paths: [],
                acceptance_checks: [],
                setup_outputs: [],
                setup_inputs: nil,
                env: %{},
                sandbox: true,
                base: nil,
                account: nil,
                build: nil
              ]

  @type diagnostic :: %{required(:glob) => String.t(), required(:argv) => [String.t()]}
  @type t :: %__MODULE__{
          root: Path.t(),
          name: String.t(),
          checks: [CheckSpec.t()],
          format: [String.t()] | nil,
          acceptance_checks: [CheckSpec.t()],
          setup: [CheckSpec.t()],
          setup_outputs: [String.t()],
          setup_inputs: [String.t()] | nil,
          fix: [CheckSpec.t()],
          diagnose: [diagnostic()],
          protected_paths: [String.t()],
          gate_paths: [String.t()],
          domains: %{optional(String.t()) => [String.t()]},
          env: %{optional(String.t()) => String.t()},
          sandbox: boolean(),
          base: String.t() | nil,
          account: String.t() | nil,
          build:
            %{
              optional(:recipe) => String.t(),
              optional(:roles) => map(),
              optional(:plan_max_words) => pos_integer() | nil
            }
            | nil
        }
end
