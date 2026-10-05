defmodule Kogen.Workspace.Identity do
  @moduledoc false

  alias Kogen.Workspace.Git

  @spec read(Path.t(), %{String.t() => String.t()}) :: {:ok, String.t()} | {:error, term()}
  def read(repo, git_env) do
    case Git.run(repo, ["var", "GIT_AUTHOR_IDENT"], git_env) do
      {:ok, 0, identity} -> parse_identity(String.trim(identity))
      {:ok, _status, _output} -> {:error, :git_identity_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_identity(identity) do
    case Regex.run(~r/\A(.+ <[^>\r\n]+>) \d+ [+-]\d{4}\z/, identity, capture: :all_but_first) do
      [approver] -> {:ok, approver}
      _invalid -> {:error, :git_identity_unavailable}
    end
  end
end
