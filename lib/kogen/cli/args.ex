defmodule Kogen.Cli.Args do
  @moduledoc false

  defstruct [
    :command,
    :project,
    :origin,
    :base,
    :by,
    :account_label,
    positionals: [],
    force: false,
    json: false,
    watch: false,
    detach: false
  ]

  @type t :: %__MODULE__{
          command: atom(),
          project: Path.t() | nil,
          origin: Path.t() | nil,
          base: String.t() | nil,
          by: String.t() | nil,
          account_label: String.t() | nil,
          positionals: [String.t()],
          force: boolean(),
          json: boolean(),
          watch: boolean(),
          detach: boolean()
        }
end
