defmodule Kogen.Kernel.Approval do
  @moduledoc false

  alias Kogen.Contracts.Intent, as: IntentData
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project, as: ProjectData
  alias Kogen.Contracts.ShapeWarning
  alias Kogen.Contracts.ShapeWarningCodec
  alias Kogen.Engine.Runtime
  alias Kogen.Intent
  alias Kogen.Kernel.Types.ApprovalPreview
  alias Kogen.Proc
  alias Kogen.Project
  alias Kogen.State
  alias Kogen.State.Approval, as: ApprovalRecord
  alias Kogen.Workspace

  @spec prepare(String.t(), Path.t(), Path.t(), String.t(), String.t(), map()) ::
          {:ok, ApprovalPreview.t()} | {:error, term()}
  def prepare(slug, project_root, origin, base, by, env) do
    git_env = Runtime.git_environment(env)

    with :ok <- valid_request(slug, project_root, origin, base, by),
         {:ok, project} <- Project.load(project_root),
         {:ok, bytes} <- read_intent(project_root, slug),
         {:ok, intent} <- Intent.parse_binary(bytes, intent_path(slug)),
         :ok <- clean_intent(intent),
         {:ok, warnings} <- read_shape_warnings(project_root, slug, bytes),
         {:ok, acceptance_files} <- acceptance_files(project_root, slug),
         :ok <- acceptance_checks(project_root, project, slug, acceptance_files, env),
         {:ok, base_sha} <- Workspace.ref_read(origin, "refs/heads/#{base}", git_env),
         {:ok, protected_manifest} <-
           protected_manifest(project_root, project, slug, bytes, acceptance_files) do
      approval = %ApprovalRecord{
        slug: slug,
        intent_bytes: bytes,
        intent_sha256: Intent.hash(bytes),
        target_branch: base,
        base_sha: base_sha,
        domains: intent.domains,
        acceptance_files: acceptance_files,
        protected_manifest: protected_manifest,
        by: by,
        at: DateTime.utc_now()
      }

      {:ok,
       %ApprovalPreview{
         approval: approval,
         intent: intent,
         project_root: project_root,
         origin: origin,
         git_env: git_env,
         warnings: warnings
       }}
    end
  end

  @spec commit(ApprovalPreview.t()) :: {:ok, String.t()} | {:error, term()}
  def commit(%ApprovalPreview{} = preview) do
    State.approve(preview.origin, preview.approval, preview.git_env)
  end

  @spec warnings_text([ShapeWarning.t()]) :: String.t()
  def warnings_text([]), do: ""

  def warnings_text(warnings) do
    lines =
      Enum.map_join(warnings, "", fn warning ->
        items = Enum.join(warning.item_ids, ", ")
        "  - #{warning.code}: #{items} — #{warning.message}\n"
      end)

    "Warnings\n" <> lines
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

  defp clean_intent(%IntentData{} = intent) do
    case Intent.lint(intent) do
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
    relative = acceptance_source_path(slug)

    case File.read(Path.join(project_root, relative)) do
      {:ok, bytes} -> {:ok, %{relative => bytes}}
      {:error, reason} -> {:error, {:acceptance_unavailable, reason}}
    end
  end

  defp acceptance_checks(_root, %ProjectData{acceptance_checks: []}, _slug, _files, _env), do: :ok

  defp acceptance_checks(root, %ProjectData{} = project, slug, files, env) do
    relative = candidate_acceptance_path(slug)
    bytes = Map.fetch!(files, acceptance_source_path(slug))
    env = Map.merge(env, project.env)

    with {:ok, created?} <- stage_candidate(root, relative, bytes) do
      result = run_acceptance_checks(project.acceptance_checks, root, relative, env)
      if created?, do: cleanup_candidate(root, relative, result), else: result
    end
  end

  defp stage_candidate(root, relative, bytes) do
    path = Path.join(root, relative)

    case File.read(path) do
      {:ok, ^bytes} -> {:ok, false}
      {:ok, _existing} -> {:error, {:acceptance_check_path_conflict, relative}}
      {:error, :enoent} -> create_candidate(root, path, relative, bytes)
      {:error, reason} -> {:error, {:acceptance_check_path_unavailable, relative, reason}}
    end
  end

  defp create_candidate(root, path, relative, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes, [:binary, :exclusive]) do
      {:ok, true}
    else
      {:error, :eexist} -> stage_candidate(root, relative, bytes)
      {:error, reason} -> {:error, {:acceptance_check_path_unavailable, relative, reason}}
    end
  end

  defp run_acceptance_checks(specs, root, relative, env) do
    Enum.reduce_while(specs, :ok, fn spec, :ok ->
      argv = Enum.map(spec.argv, &if(&1 == "{path}", do: relative, else: &1))

      case Proc.run(argv, cd: root, env: env, timeout_ms: spec.timeout_ms) do
        {:ok, %ProcResult{exit_status: 0, timed_out: false}} -> {:cont, :ok}
        result -> {:halt, {:error, {:acceptance_check_failed, spec.name, result}}}
      end
    end)
  end

  defp cleanup_candidate(root, relative, result) do
    case File.rm(Path.join(root, relative)) do
      :ok -> result
      {:error, :enoent} -> result
      {:error, reason} -> {:error, {:acceptance_check_cleanup_failed, relative, reason}}
    end
  end

  defp protected_manifest(project_root, %ProjectData{} = project, slug, intent_bytes, files) do
    protected_paths = Enum.flat_map(project.protected_paths, &expand_glob(project_root, &1))

    approved_files = [
      {intent_path(slug), intent_bytes},
      {acceptance_source_path(slug), Map.fetch!(files, acceptance_source_path(slug))},
      {candidate_acceptance_path(slug), Map.fetch!(files, acceptance_source_path(slug))}
    ]

    with {:ok, manifest} <- hash_paths(project_root, protected_paths) do
      add_approved_files(manifest, approved_files)
    end
  end

  defp expand_glob(root, pattern) do
    root
    |> Path.join(pattern)
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp hash_paths(root, paths) do
    paths
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, manifest} ->
      case File.read(Path.join(root, path)) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(manifest, path, sha256(bytes))}}
        {:error, reason} -> {:halt, {:error, {:protected_file_unavailable, path, reason}}}
      end
    end)
  end

  defp add_approved_files(manifest, files) do
    {:ok,
     Enum.reduce(files, manifest, fn {path, bytes}, current ->
       Map.put(current, path, sha256(bytes))
     end)}
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
  defp acceptance_source_path(slug), do: ".kogen/acceptance/#{slug}_test.exs"
  defp candidate_acceptance_path(slug), do: "test/acceptance/#{slug}_test.exs"
  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
