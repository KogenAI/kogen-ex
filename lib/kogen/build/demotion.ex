defmodule Kogen.Build.Demotion do
  @moduledoc """
  Acceptance items the test auditor demoted to advisory for one Build. Their tests are
  excluded from `mix test` checks by intent tag, and their ledger failures no longer count.
  """

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project

  @doc "Appends `--exclude intent:<slug>/<id>` for each demoted item to every `mix test` check."
  @spec exclude(Project.t(), String.t(), [String.t()]) :: Project.t()
  def exclude(%Project{} = project, _slug, []), do: project

  def exclude(%Project{checks: checks} = project, slug, ids) do
    flags = Enum.flat_map(ids, &["--exclude", "intent:#{slug}/#{&1}"])

    %{
      project
      | checks:
          Enum.map(checks, fn %CheckSpec{argv: argv} = spec ->
            if mix_test?(argv), do: %{spec | argv: argv ++ flags}, else: spec
          end)
    }
  end

  @doc """
  Acceptance failures that still count. The ledger adds `suite` when the acceptance run
  exits non-zero; it is dropped when every failing item it reflects was demoted.
  """
  @spec remaining([String.t()], [String.t()]) :: [String.t()]
  def remaining(failed_ids, demoted) do
    items = failed_ids -- ["suite"]
    left = items -- demoted

    cond do
      "suite" not in failed_ids -> left
      left == [] and items != [] -> []
      true -> left ++ ["suite"]
    end
  end

  defp mix_test?(argv) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [executable, command] ->
      command == "test" and Path.basename(executable) == "mix"
    end)
  end
end
