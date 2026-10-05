defmodule Kogen.Checks.ShapeValidation do
  @moduledoc false

  @enforce_keys [:workdir, :project, :intent, :acceptance_bytes, :run_dir, :env, :git_env]
  defstruct @enforce_keys ++ [sandbox: nil]

  @type t :: %__MODULE__{
          workdir: Path.t(),
          project: Kogen.Contracts.Project.t(),
          intent: Kogen.Contracts.Intent.t(),
          acceptance_bytes: binary(),
          run_dir: Path.t(),
          env: %{String.t() => String.t()},
          git_env: %{String.t() => String.t()},
          sandbox: Kogen.Proc.Sandbox.t() | nil
        }
end

defmodule Kogen.Checks.ShapeFormatRequest do
  @moduledoc false

  @enforce_keys [:workdir, :slug, :written_paths, :project, :run_dir, :env]
  defstruct @enforce_keys ++ [sandbox: nil]

  @type t :: %__MODULE__{
          workdir: Path.t(),
          slug: String.t(),
          written_paths: [Path.t()],
          project: Kogen.Contracts.Project.t(),
          run_dir: Path.t(),
          env: %{String.t() => String.t()},
          sandbox: Kogen.Proc.Sandbox.t() | nil
        }
end

defmodule Kogen.Checks do
  @moduledoc "Runs deterministic project verification and records its results."
  use Boundary,
    deps: [Kogen.Contracts, Kogen.Proc, Kogen.Workspace, Kogen.Project],
    exports: [Feedback, LedgerRow, ShapeValidation, ShapeFormatRequest]

  alias Kogen.Checks.Fixer
  alias Kogen.Checks.Ledger
  alias Kogen.Checks.LedgerRow
  alias Kogen.Checks.Runner
  alias Kogen.Checks.ShapeFormatRequest
  alias Kogen.Checks.ShapeFormatter
  alias Kogen.Checks.ShapeValidation
  alias Kogen.Checks.Shaping
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project
  alias Kogen.Proc.Sandbox

  @type run_result ::
          {:ok,
           %{
             tree: String.t(),
             receipts: [Kogen.Contracts.Receipt.t()],
             status: :pass | {:fail, [String.t()]},
             feedback: String.t(),
             exit_levels: [{String.t(), 0..3}],
             checks: [map()],
             warnings: [String.t()]
           }}
          | {:error, Failure.t()}

  @spec fix(Path.t(), Project.t(), Path.t()) :: {:ok, [ProcResult.t()]} | {:error, Failure.t()}
  def fix(workdir, project, run_dir), do: fix(workdir, project, run_dir, %{})

  @spec fix(Path.t(), Project.t(), Path.t(), %{String.t() => String.t()}) ::
          {:ok, [ProcResult.t()]} | {:error, Failure.t()}
  def fix(workdir, project, run_dir, env), do: Fixer.run(workdir, project, run_dir, env)

  @spec fix(
          Path.t(),
          Project.t(),
          Path.t(),
          %{String.t() => String.t()},
          Sandbox.t() | nil
        ) ::
          {:ok, [ProcResult.t()]} | {:error, Failure.t()}
  def fix(workdir, project, run_dir, env, sandbox),
    do: Fixer.run(workdir, project, run_dir, env, sandbox)

  @spec run_all(Path.t(), Project.t(), Path.t(), %{String.t() => String.t()}) :: run_result()
  def run_all(workdir, project, run_dir, git_env),
    do: run_all(workdir, project, run_dir, git_env, git_env)

  @spec run_all(
          Path.t(),
          Project.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()}
        ) :: run_result()
  def run_all(workdir, project, run_dir, env, git_env),
    do: Runner.run_all(workdir, project, run_dir, env, git_env)

  @spec run_all(
          Path.t(),
          Project.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()},
          Sandbox.t() | map() | nil
        ) :: run_result()
  def run_all(workdir, project, run_dir, env, git_env, options),
    do: Runner.run_all(workdir, project, run_dir, env, git_env, options)

  @spec acceptance(Path.t(), Intent.t(), Path.t()) ::
          {:ok, %{status: :pass | {:fail, [String.t()]}, ledger: [LedgerRow.t()]}}
          | {:error, Failure.t()}
  def acceptance(workdir, intent, run_dir), do: acceptance(workdir, intent, run_dir, %{}, %{})

  @spec acceptance(
          Path.t(),
          Intent.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()}
        ) ::
          {:ok, %{status: :pass | {:fail, [String.t()]}, ledger: [LedgerRow.t()]}}
          | {:error, Failure.t()}
  def acceptance(workdir, intent, run_dir, env, git_env),
    do: Ledger.acceptance(workdir, intent, run_dir, env, git_env)

  @spec acceptance(
          Path.t(),
          Intent.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()},
          Sandbox.t() | nil
        ) ::
          {:ok, %{status: :pass | {:fail, [String.t()]}, ledger: [LedgerRow.t()]}}
          | {:error, Failure.t()}
  def acceptance(workdir, intent, run_dir, env, git_env, sandbox),
    do: Ledger.acceptance(workdir, intent, run_dir, env, git_env, sandbox)

  @spec red_on_base(Path.t(), Intent.t(), Path.t()) :: :ok | {:error, Failure.t()}
  def red_on_base(workdir, intent, run_dir), do: red_on_base(workdir, intent, run_dir, %{}, %{})

  @spec red_on_base(
          Path.t(),
          Intent.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()}
        ) :: :ok | {:error, Failure.t()}
  def red_on_base(workdir, intent, run_dir, env, git_env),
    do: Ledger.red_on_base(workdir, intent, run_dir, env, git_env)

  @spec red_on_base(
          Path.t(),
          Intent.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()},
          Sandbox.t() | nil
        ) :: :ok | {:error, Failure.t()}
  def red_on_base(workdir, intent, run_dir, env, git_env, sandbox),
    do: Ledger.red_on_base(workdir, intent, run_dir, env, git_env, sandbox)

  @spec validate_shape(ShapeValidation.t()) ::
          {:ok, [Kogen.Contracts.ShapeWarning.t()]} | {:error, Failure.t()}
  def validate_shape(%ShapeValidation{} = request), do: Shaping.validate(request)

  @spec format_shape_files(ShapeFormatRequest.t()) ::
          :ok | {:warning, Failure.t()} | {:error, Failure.t()}
  def format_shape_files(%ShapeFormatRequest{} = request),
    do: ShapeFormatter.format_files(request)

  @spec protected_violations(
          Path.t(),
          String.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()}
        ) :: {:ok, [String.t()]} | {:error, term()}
  def protected_violations(workdir, base_sha, manifest, git_env),
    do: Kogen.Workspace.protected_violations(workdir, base_sha, manifest, git_env)

  @spec scope_violations(
          Path.t(),
          String.t(),
          Intent.t(),
          Project.t(),
          [String.t()],
          %{String.t() => String.t()}
        ) :: {:ok, [String.t()]} | {:error, term()}
  def scope_violations(workdir, base_sha, intent, project, allowed_extra, git_env),
    do:
      Kogen.Workspace.scope_violations(workdir, base_sha, intent, project, allowed_extra, git_env)
end
