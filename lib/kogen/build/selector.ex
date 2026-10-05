defmodule Kogen.Build.Selector do
  @moduledoc """
  Ranks Candidates from one Build. Better means, in order: green on every check other than
  acceptance items, fewer failing acceptance items, fewer failing tests, then a smaller diff.
  A fully green Candidate has no failures and so always outranks a red one.

  Green Candidates that were cross-checked against each other's tests rank by more of the
  others' tests passed (`cross_passed`), then more kept edge tests passed (`edge_passed`), then
  fewer gate warnings, then a smaller diff. Without a completed cross-check or edge probe those
  metrics are absent and the smaller diff wins.
  """

  @unknown 1_000_000

  @type metrics :: %{
          optional(:checks_green) => boolean(),
          optional(:failing_acceptance) => non_neg_integer() | nil,
          optional(:failing_tests) => non_neg_integer() | nil,
          optional(:diff_lines) => non_neg_integer() | nil,
          optional(:cross_passed) => non_neg_integer(),
          optional(:edge_passed) => non_neg_integer(),
          optional(:gate_warnings) => non_neg_integer()
        }
  @type candidate :: %{
          required(:status) => :green | :failed | atom(),
          required(:metrics) => metrics(),
          optional(atom()) => term()
        }

  @doc "The best candidate; earlier entries win ties."
  @spec best([candidate(), ...]) :: candidate()
  def best([_ | _] = candidates), do: Enum.min_by(candidates, &key/1)

  @spec rank([candidate()]) :: [candidate()]
  def rank(candidates), do: Enum.sort_by(candidates, &key/1)

  @spec key(candidate()) ::
          {0 | 1 | 2, integer(), integer(), non_neg_integer(), non_neg_integer()}
  def key(%{status: :green, metrics: metrics}) do
    {0, -Map.get(metrics, :cross_passed, 0), -Map.get(metrics, :edge_passed, 0),
     Map.get(metrics, :gate_warnings, 0), count(metrics, :diff_lines)}
  end

  def key(%{metrics: metrics}) do
    {if(Map.get(metrics, :checks_green) == true, do: 1, else: 2),
     count(metrics, :failing_acceptance), count(metrics, :failing_tests),
     count(metrics, :diff_lines), 0}
  end

  defp count(metrics, key) do
    case Map.get(metrics, key) do
      value when is_integer(value) and value >= 0 -> value
      _unknown -> @unknown
    end
  end
end
