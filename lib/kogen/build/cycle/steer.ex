defmodule Kogen.Build.Cycle.Steer do
  @moduledoc false

  # A ladder Build steers instead of stopping: an unusable check run is fed back to the
  # builder as a repair, and other environment or controller signals from a Candidate stage
  # end only that rung. Signing in again, landing and Kogen's own journal stay terminal.

  alias Kogen.Build.Cycle.State
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure

  @candidate_stages [:plan, :develop, :fix, :check, :audit]
  @terminal_reasons [:login, :state_write_failed, :landing_failed]

  @spec decide(State.t(), atom(), Failure.t()) ::
          {:repair, atom(), map()} | {:next_rung, term(), atom()} | :stop
  def decide(%State{} = state, stage, %Failure{class: class, reason: reason})
      when class in [:environment, :controller] do
    cond do
      Recipe.ladder(state.recipe) == nil ->
        :stop

      stage not in @candidate_stages or reason in @terminal_reasons ->
        :stop

      stage == :develop and reason == :check_unavailable ->
        {:repair, reason, %{failed_stage: stage}}

      true ->
        {:next_rung, {class, reason}, class}
    end
  end

  def decide(_state, _stage, _failure), do: :stop
end
