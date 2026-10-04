defmodule Kogen.E2e do
  @moduledoc false
  use Boundary,
    deps: [
      Kogen.Contracts,
      Kogen.Engine,
      Kogen.Kernel,
      Kogen.Proc,
      Kogen.Project,
      Kogen.Shaper,
      Kogen.State,
      Kogen.Testkit,
      Kogen.Workspace,
      ExUnit
    ],
    exports: [
      Build,
      Build.Environment,
      Build.Fixture,
      Build.Options,
      Build.Result,
      Build.Signal,
      ScriptedProvider
    ]
end

defmodule Kogen.E2e.Build.Options do
  @moduledoc false

  @enforce_keys [:seed_project]
  defstruct [
    :seed_project,
    :move_base_on,
    recipe: "staged",
    builder_model: "scripted-model",
    builder_effort: "medium"
  ]

  @type t :: %__MODULE__{
          seed_project: Path.t(),
          move_base_on: atom() | nil,
          recipe: String.t(),
          builder_model: String.t(),
          builder_effort: String.t()
        }
end

defmodule Kogen.E2e.Build.Fixture do
  @moduledoc false

  @enforce_keys [
    :project_root,
    :workspace_root,
    :home,
    :origin,
    :approved_base,
    :approval_commit,
    :git_env
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          project_root: Path.t(),
          workspace_root: Path.t(),
          home: Path.t(),
          origin: Path.t(),
          approved_base: String.t(),
          approval_commit: String.t(),
          git_env: %{String.t() => String.t()}
        }
end

defmodule Kogen.E2e.Build.Result do
  @moduledoc false

  alias Kogen.E2e.Build.Fixture

  @enforce_keys [:build, :events, :fixture, :run_status, :claim_released]
  defstruct @enforce_keys ++ [provider_requests: []]

  @doc "A Build refused before it starts has no run; report the refusal as the outcome."
  @spec refused(Fixture.t(), term()) :: t()
  def refused(fixture, reason) do
    %__MODULE__{
      build: %{status: :refused, reason: reason},
      events: [],
      fixture: fixture,
      run_status: nil,
      claim_released: true,
      provider_requests: []
    }
  end

  @type t :: %__MODULE__{
          build: Kogen.Engine.Build.Result.t(),
          events: [Kogen.State.Event.t()],
          fixture: Fixture.t(),
          run_status: Kogen.State.Run.status(),
          claim_released: boolean(),
          provider_requests: [Kogen.Contracts.ModelRequest.t()]
        }
end
