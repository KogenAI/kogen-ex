defmodule Kogen.Kernel.Approval.Request do
  @moduledoc false

  @enforce_keys [:slug, :project_root, :origin, :base, :by, :env]
  defstruct @enforce_keys ++ [runtime: nil, home: nil]

  @type t :: %__MODULE__{
          slug: String.t(),
          project_root: Path.t(),
          origin: Path.t(),
          base: String.t(),
          by: String.t(),
          env: %{String.t() => String.t()},
          runtime: Kogen.Engine.Runtime.t() | nil,
          home: Path.t() | nil
        }
end

defmodule Kogen.Kernel.Approval do
  @moduledoc false

  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.Intent, as: IntentData
  alias Kogen.Contracts.ShapeWarning
  alias Kogen.Contracts.ShapeWarningCodec
  alias Kogen.Contracts.Stack
  alias Kogen.Engine.Runtime
  alias Kogen.Intent
  alias Kogen.Kernel.Approval.Request
  alias Kogen.Kernel.ApprovalChecks
  alias Kogen.Kernel.ApprovalManifest
  alias Kogen.Kernel.Types.ApprovalPreview
  alias Kogen.Project
  alias Kogen.State
  alias Kogen.State.Approval, as: ApprovalRecord
  alias Kogen.Workspace

  @spec prepare(String.t(), Path.t(), Path.t(), String.t(), String.t(), map()) ::
          {:ok, ApprovalPreview.t()} | {:error, term()}
  def prepare(slug, project_root, origin, base, by, env) do
    prepare(%Request{
      slug: slug,
      project_root: project_root,
      origin: origin,
      base: base,
      by: by,
      env: env
    })
  end

  @spec prepare(Request.t()) :: {:ok, ApprovalPreview.t()} | {:error, term()}
  def prepare(%Request{} = request) do
    git_env = Runtime.git_environment(request.env)

    with {:ok, approval, intent, warnings} <- prepare_approval(request, git_env) do
      {:ok,
       %ApprovalPreview{
         approval: approval,
         intent: intent,
         project_root: request.project_root,
         origin: request.origin,
         git_env: git_env,
         warnings:
           Enum.uniq_by(
             warnings ++ Intent.style_warnings(intent),
             &{&1.code, &1.item_ids, &1.message}
           )
       }}
    end
  end

  defp prepare_approval(%Request{} = request, git_env) do
    with :ok <- valid_request(request),
         {:ok, project} <- Project.load(request.project_root),
         {:ok, bytes} <- read_intent(request.project_root, request.slug),
         {:ok, intent} <- Intent.parse_binary(bytes, intent_path(request.slug)),
         :ok <- clean_intent(intent),
         {:ok, warnings} <- read_shape_warnings(request.project_root, request.slug, bytes),
         {:ok, acceptance_files} <- acceptance_files(request.project_root, request.slug),
         {:ok, base_sha} <-
           Workspace.ref_read(request.origin, "refs/heads/#{request.base}", git_env),
         {:ok, _evidence} <- recheck(intent, request, base_sha, git_env),
         {:ok, check_baseline} <-
           ApprovalChecks.run(request, project, base_sha, acceptance_files),
         {:ok, protected_manifest} <-
           ApprovalManifest.build(
             request,
             base_sha,
             git_env,
             project,
             %{bytes: bytes, changes_gate: intent.changes_gate},
             acceptance_files
           ) do
      approval = %ApprovalRecord{
        slug: request.slug,
        intent_bytes: bytes,
        intent_sha256: Intent.hash(bytes),
        target_branch: request.base,
        base_sha: base_sha,
        domains: intent.domains,
        acceptance_files: acceptance_files,
        protected_manifest: protected_manifest,
        check_baseline: check_baseline,
        by: request.by,
        at: DateTime.utc_now()
      }

      {:ok, approval, intent, warnings}
    end
  end

  defp recheck(intent, request, base, env),
    do: Kogen.Shaping.recheck(%{intent | blocks_on: []}, request.origin, base, request.base, env)

  @spec commit(ApprovalPreview.t()) :: {:ok, String.t()} | {:error, term()}
  def commit(%ApprovalPreview{} = preview) do
    State.approve(preview.origin, preview.approval, preview.git_env)
  end

  @spec warnings_text([ShapeWarning.t()], [map()]) :: String.t()
  def warnings_text(warnings, check_baseline \\ []) do
    lines =
      Enum.map_join(warnings, "", fn warning ->
        items = if warning.item_ids == [], do: "-", else: Enum.join(warning.item_ids, ", ")
        "  - #{warning.code}: #{items} — #{warning.message}\n"
      end)

    check_warning = CheckBaseline.approval_warning(check_baseline)

    if lines == "" and check_warning == "",
      do: "",
      else: "Warnings\n" <> lines <> check_warning
  end

  defp valid_request(slug, project_root, origin, base, by) do
    if valid_slug?(slug) and absolute_directory?(project_root) and absolute_directory?(origin) and
         valid_branch?(base) and is_binary(by) and String.trim(by) != "" and
         not String.contains?(by, ["\n", "\r"]) do
      :ok
    else
      {:error, :invalid_approval_request}
    end
  end

  defp valid_request(%Request{} = request) do
    valid_request(request.slug, request.project_root, request.origin, request.base, request.by)
  end

  defp clean_intent(%IntentData{} = intent) do
    case Intent.structural_issues(intent) do
      [] -> :ok
      issues -> {:error, {:lint, issues}}
    end
  end

  defp read_shape_warnings(project_root, slug, intent_bytes) do
    path = Path.join([project_root, ".kogen", "intents", slug, "shape-warnings.json"])

    case File.read(path) do
      {:ok, bytes} ->
        case ShapeWarningCodec.decode(bytes, Intent.hash(intent_bytes)) do
          {:ok, warnings} -> {:ok, warnings}
          {:error, :invalid} -> {:error, {:shape_warnings_invalid, path}}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:shape_warnings_unavailable, path, reason}}
    end
  end

  defp read_intent(project_root, slug) do
    case File.read(Path.join(project_root, intent_path(slug))) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:intent_unavailable, reason}}
    end
  end

  defp acceptance_files(project_root, slug) do
    relative = Stack.acceptance_source(project_root, slug)

    case File.read(Path.join(project_root, relative)) do
      {:ok, bytes} -> {:ok, %{relative => bytes}}
      {:error, reason} -> {:error, {:acceptance_unavailable, reason}}
    end
  end

  defp valid_slug?(slug),
    do: is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)

  defp valid_branch?(branch) when is_binary(branch) do
    branch != "" and not String.starts_with?(branch, "/") and
      not Enum.any?(String.split(branch, "/"), &(&1 in ["", ".", "..", ".lock"])) and
      Regex.match?(~r{\A[A-Za-z0-9._/-]+\z}, branch)
  end

  defp valid_branch?(_branch), do: false

  defp absolute_directory?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.dir?(path)

  defp intent_path(slug), do: ".kogen/intents/#{slug}/intent.md"
end
