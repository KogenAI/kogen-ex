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

  @spec snapshot(Path.t(), String.t(), %{String.t() => String.t()}, boolean()) ::
          {:ok, %{approvals: map(), landed: map(), claim_run_id: String.t() | nil}}
          | {:error, term()}
  def snapshot(repo, branch, git_env, include_claim?) do
    with {:ok, approvals} <- approval_refs(repo, git_env),
         {:ok, landed} <- landed_intents(repo, branch, git_env),
         {:ok, claim_run_id} <- claim_run_id(repo, git_env, include_claim?) do
      {:ok, %{approvals: approvals, landed: landed, claim_run_id: claim_run_id}}
    end
  end

  defp approval_refs(repo, git_env) do
    case Git.run(
           repo,
           ["for-each-ref", "--format=%(refname)%00%(objectname)", "refs/kogen/intents/"],
           git_env
         ) do
      {:ok, 0, output} ->
        approvals =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, refs ->
            case String.split(line, <<0>>, parts: 2) do
              ["refs/kogen/intents/" <> slug, sha] -> Map.put(refs, slug, String.trim(sha))
              _other -> refs
            end
          end)

        {:ok, approvals}

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
      {:ok, 0, output} -> {:ok, parse_landed_intents(output)}
      {:ok, _status, _output} -> {:error, :git_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_landed_intents(output) do
    output
    |> String.split(<<0>>)
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, fn
      [sha, slug | _rest], landed ->
        sha = String.trim(sha)
        slug = String.trim(slug)

        if valid_sha?(sha) and valid_intent_slug?(slug),
          do: Map.put_new(landed, slug, sha),
          else: landed

      _other, landed ->
        landed
    end)
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
