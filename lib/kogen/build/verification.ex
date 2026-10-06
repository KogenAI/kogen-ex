defmodule Kogen.Build.Verification do
  @moduledoc "Pure verdicts for candidate checks, acceptance demotions and verified trees."

  alias Kogen.Build.Demotion
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent

  @no_change_item_passed "no_change_item_passed"

  @spec passed(Recipe.t(), [String.t()], map(), map()) :: :ok | {:error, Failure.t()}
  def passed(recipe, remaining, checks, acceptance) do
    cond do
      checks.status == :pass and remaining == [] ->
        :ok

      checks.status == :pass and Recipe.auditor(recipe) != nil ->
        {:error, failure(:acceptance_red, "acceptance=#{inspect({:fail, remaining})}")}

      true ->
        {:error, failure(:verification_failed, detail(checks, acceptance))}
    end
  end

  @spec remaining(Intent.t(), [map()], map()) :: [String.t()]
  def remaining(intent, demoted, %{status: status} = acceptance) do
    left =
      case status do
        :pass -> []
        {:fail, ids} -> Demotion.remaining(ids, Enum.map(demoted, & &1.id))
      end

    if left == [] and demoted != [] and not change_item_passed?(intent, acceptance),
      do: [@no_change_item_passed],
      else: left
  end

  def no_change_item_passed, do: @no_change_item_passed

  def unchanged(tree, tree), do: :ok

  def unchanged(_expected, _actual),
    do: {:error, failure(:verification_failed, "Acceptance changed the verified tree.")}

  def acceptance_status(:pass), do: :pass
  def acceptance_status({:fail, ids}), do: %{status: :fail, failed_ids: ids}

  # Demotion cannot turn a Candidate green unless it passes at least one change item (an
  # Acceptance item verified by a test that was red on the base).
  defp change_item_passed?(intent, acceptance) do
    change = for %{verify: :test, id: id} <- intent.acceptance, do: "#{intent.slug}/#{id}"
    passed = for %{status: :passed, tag: tag} <- Map.get(acceptance, :ledger, []), do: tag
    change == [] or Enum.any?(change, &(&1 in passed))
  end

  defp detail(checks, acceptance) do
    feedback = Map.get(checks, :feedback, "")
    status = "acceptance=#{inspect(acceptance.status)}"

    if feedback == "",
      do: "checks=#{inspect(checks.status)} " <> status,
      else: feedback <> "\n" <> status
  end

  defp failure(reason, detail), do: %Failure{class: :candidate, reason: reason, detail: detail}
end
