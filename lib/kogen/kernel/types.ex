defmodule Kogen.Kernel.Types.ApprovalPreview do
  @moduledoc false

  @enforce_keys [:approval, :intent, :project_root, :origin, :git_env]
  defstruct @enforce_keys ++ [warnings: []]

  @type t :: %__MODULE__{
          approval: Kogen.State.Approval.t(),
          intent: Kogen.Contracts.Intent.t(),
          project_root: Path.t(),
          origin: Path.t(),
          git_env: %{String.t() => String.t()},
          warnings: [Kogen.Contracts.ShapeWarning.t()]
        }
end

defmodule Kogen.Kernel.Types.IntentStatus do
  @moduledoc false

  @enforce_keys [:slug, :status, :run_id, :landed_sha]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          slug: String.t(),
          status: Kogen.State.status(),
          run_id: String.t() | nil,
          landed_sha: String.t() | nil
        }
end

defmodule Kogen.Kernel.Types.BuildOptions do
  @moduledoc false

  @enforce_keys [:slug, :project_root, :origin, :base, :model, :effort]
  defstruct [
    :slug,
    :project_root,
    :origin,
    :base,
    :model,
    :effort,
    borrow: nil,
    label: "default",
    recipe: "staged"
  ]

  @type t :: %__MODULE__{
          slug: String.t(),
          project_root: Path.t(),
          origin: Path.t() | nil,
          base: String.t(),
          model: String.t(),
          effort: String.t(),
          recipe: String.t(),
          borrow: :codex | nil,
          label: String.t()
        }
end

defmodule Kogen.Kernel.Types.ShapeInputs do
  @moduledoc false

  @enforce_keys [
    :slug,
    :project_root,
    :task,
    :model,
    :effort,
    :project,
    :provider_config,
    :runtime,
    :process_env,
    :run_dir,
    :home
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          slug: String.t(),
          project_root: Path.t(),
          task: String.t(),
          model: String.t(),
          effort: String.t(),
          project: Kogen.Contracts.Project.t(),
          provider_config: term(),
          runtime: Kogen.Engine.Runtime.t(),
          process_env: %{String.t() => String.t()},
          run_dir: Path.t(),
          home: Path.t()
        }
end

defmodule Kogen.Kernel.CLI.Args do
  @moduledoc false

  defstruct [
    :command,
    :project,
    :origin,
    :base,
    :model,
    :effort,
    :by,
    :task_file,
    :account_label,
    :borrow,
    :recipe,
    positionals: [],
    yes: false,
    json: false
  ]

  @type t :: %__MODULE__{
          command: atom(),
          project: Path.t() | nil,
          origin: Path.t() | nil,
          base: String.t() | nil,
          model: String.t() | nil,
          effort: String.t() | nil,
          by: String.t() | nil,
          task_file: Path.t() | nil,
          account_label: String.t() | nil,
          borrow: String.t() | nil,
          recipe: String.t() | nil,
          positionals: [String.t()],
          yes: boolean(),
          json: boolean()
        }
end
