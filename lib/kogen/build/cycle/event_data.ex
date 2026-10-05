defmodule Kogen.Build.Cycle.EventData do
  @moduledoc false

  @landing_keys [:approval_commit, :run_id, :expected_parent, :final_tree, :candidate_commit]

  @spec landing_identity(map()) :: {:ok, map()} | :error
  def landing_identity(data) do
    if Enum.all?(@landing_keys, &is_binary(Map.get(data, &1))) do
      {:ok, Map.new(@landing_keys, &{&1, Map.fetch!(data, &1)})}
    else
      :error
    end
  end

  @spec tree(map()) :: String.t() | nil
  def tree(data), do: Map.get(data, :tree) || Map.get(data, :candidate_tree)

  @doc "A repair that leaves the Candidate tree exactly as it was made no progress."
  @spec same_repaired_tree?(String.t() | nil, String.t() | nil) :: boolean()
  def same_repaired_tree?(repair_tree, tree), do: is_binary(repair_tree) and repair_tree == tree
end
