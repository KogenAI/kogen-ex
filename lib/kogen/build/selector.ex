defmodule Kogen.Build.Selector do
  @moduledoc """
  Ranks Candidates from one Build. Better means, in order: green on every check other than
  acceptance items, fewer failing acceptance items, fewer failing tests, then a smaller diff.
  A fully green Candidate has no failures and so always outranks a red one.
  """

  @unknown 1_000_000

  @type metrics :: %{
          optional(:checks_green) => boolean(),
          optional(:failing_acceptance) => non_neg_integer() | nil,
          optional(:failing_tests) => non_neg_integer() | nil,
          optional(:diff_lines) => non_neg_integer() | nil
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

  @spec key(candidate()) :: {0 | 1, non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def key(%{status: :green, metrics: metrics}), do: {0, 0, 0, count(metrics, :diff_lines)}

  def key(%{metrics: metrics}) do
    {if(Map.get(metrics, :checks_green) == true, do: 0, else: 1),
     count(metrics, :failing_acceptance), count(metrics, :failing_tests),
     count(metrics, :diff_lines)}
  end

  defp count(metrics, key) do
    case Map.get(metrics, key) do
      value when is_integer(value) and value >= 0 -> value
      _unknown -> @unknown
    end
  end
end
