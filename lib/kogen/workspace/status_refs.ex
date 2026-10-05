defmodule Kogen.Workspace.StatusRefs do
  @moduledoc false

  alias Kogen.Workspace.Git
  alias Kogen.Workspace.Refs

  @spec head_branch(Path.t(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, :missing | term()}
  def head_branch(repo, _git_env) do
    head = Path.join(Git.git_dir(repo), "HEAD")

    case File.read(head) do
      {:ok, "ref: refs/heads/" <> branch} ->
        case String.trim_trailing(branch, "\n") do
          "" -> {:error, :missing}
          value -> {:ok, value}
        end

      {:ok, _detached_or_invalid} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec remote_head_branch(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def remote_head_branch(repo, remote) when is_binary(remote) do
    ref_path = Path.join(Git.git_dir(repo), "refs/remotes/#{remote}/HEAD")

    case File.read(ref_path) do
      {:ok, "ref: refs/remotes/" <> rest} ->
        case String.split(rest, "/", parts: 2) do
          [^remote, branch] when branch != "" -> {:ok, String.trim_trailing(branch, "\n")}
          _other -> {:error, :missing}
        end

      {:ok, _other} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @typedoc """
  `approvals` and `approved_at` map slugs to the approval ref tip and its commit time (Unix
  seconds); `landed` maps slugs to landing commits and `landed_order` lists them newest first.
  """
  @type snapshot :: %{
          approvals: %{String.t() => String.t()},
          approved_at: %{String.t() => integer()},
          landed: %{String.t() => String.t()},
          landed_order: [String.t()],
          claim_run_id: String.t() | nil
        }

  @spec snapshot(Path.t(), String.t(), %{String.t() => String.t()}, boolean()) ::
          {:ok, snapshot()} | {:error, term()}
  def snapshot(repo, branch, git_env, include_claim?) do
    with {:ok, approvals, approved_at} <- approval_refs(repo, git_env),
         {:ok, landed, landed_order} <- landed_intents(repo, branch, git_env),
         {:ok, claim_run_id} <- claim_run_id(repo, git_env, include_claim?) do
      {:ok,
       %{
         approvals: approvals,
         approved_at: approved_at,
         landed: landed,
         landed_order: landed_order,
         claim_run_id: claim_run_id
       }}
    end
  end

  defp approval_refs(repo, git_env) do
    case Git.run(
           repo,
           [
             "for-each-ref",
             "--format=%(refname)%00%(objectname)%00%(committerdate:unix)",
             "refs/kogen/intents/"
           ],
           git_env
         ) do
      {:ok, 0, output} ->
        rows =
          output
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line, <<0>>, parts: 3) do
              ["refs/kogen/intents/" <> slug, sha, time] -> [{slug, String.trim(sha), time}]
              _other -> []
            end
          end)

        {:ok, Map.new(rows, fn {slug, sha, _time} -> {slug, sha} end),
         Map.new(rows, fn {slug, _sha, time} -> {slug, unix_time(time)} end)}

      {:ok, _status, _output} ->
        {:error, :git_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp landed_intents(repo, branch, git_env) do
    revision = branch_ref(branch)
    format = "%H%x00%(trailers:key=Kogen-Intent,valueonly)%x00"

    case Git.run(repo, ["log", "--format=#{format}", revision], git_env) do
      {:ok, 0, output} ->
        rows = parse_landed_intents(output)
        {:ok, Map.new(Enum.reverse(rows)), rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq()}

      {:ok, _status, _output} ->
        {:error, :git_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Newest first, as git log prints them; the newest landing of a slug wins.
  defp parse_landed_intents(output) do
    output
    |> String.split(<<0>>)
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [sha, slug | _rest] ->
        sha = String.trim(sha)
        slug = String.trim(slug)
        if valid_sha?(sha) and valid_intent_slug?(slug), do: [{slug, sha}], else: []

      _other ->
        []
    end)
  end

  defp unix_time(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} -> seconds
      _invalid -> 0
    end
  end

  defp claim_run_id(_repo, _git_env, false), do: {:ok, nil}

  defp claim_run_id(repo, git_env, true) do
    case Refs.ref_read(repo, "refs/kogen/claim", git_env) do
      {:ok, sha} ->
        case Git.run(
               repo,
               ["show", "-s", "--format=%(trailers:key=Kogen-Run,valueonly)", sha],
               git_env
             ) do
          {:ok, 0, output} -> {:ok, output |> String.trim() |> nonempty()}
          {:ok, _status, _output} -> {:error, :git_failed}
          {:error, reason} -> {:error, reason}
        end

      {:error, :missing} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp branch_ref("refs/heads/" <> _branch = ref), do: ref
  defp branch_ref(branch), do: "refs/heads/#{branch}"

  defp nonempty(""), do: nil
  defp nonempty(value), do: value

  defp valid_sha?(sha), do: Regex.match?(~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/, sha)

  defp valid_intent_slug?(slug), do: Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)
end
