defmodule Kogen.Cli.Args do
  @moduledoc false

  defstruct [
    :command,
    :project,
    :origin,
    :base,
    :by,
    :task_file,
    :account_label,
    positionals: [],
    force: false,
    yes: false,
    json: false
  ]

  @type t :: %__MODULE__{
          command: atom(),
          project: Path.t() | nil,
          origin: Path.t() | nil,
          base: String.t() | nil,
          by: String.t() | nil,
          task_file: Path.t() | nil,
          account_label: String.t() | nil,
          positionals: [String.t()],
          force: boolean(),
          yes: boolean(),
          json: boolean()
        }
end
