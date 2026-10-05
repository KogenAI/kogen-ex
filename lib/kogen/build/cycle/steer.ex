defmodule Kogen.Build.Cycle.Steer do
  @moduledoc false

  # A ladder Build steers instead of stopping: an unusable check run is fed back to the
  # builder as a repair, other environment or controller signals from a Candidate stage end
  # only that rung, and a usage limit or lost login pauses the Build until the account works.
  # Landing and Kogen's own journal stay terminal.

  alias Kogen.Build.Cycle.State
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure
  alias Kogen.Resilience.Policy

  @candidate_stages [:plan, :develop, :fix, :check, :audit]
  @terminal_reasons [:state_write_failed, :landing_failed]

  @spec decide(State.t(), atom(), Failure.t()) ::
          {:repair, atom(), map()} | {:next_rung, term(), atom()} | :pause | :provider | :stop
  def decide(%State{} = state, stage, %Failure{class: class, reason: reason}) do
    ladder? = Recipe.ladder(state.recipe) != nil

    cond do
      ladder? and Policy.waitable?(reason) ->
        :pause

      class == :provider ->
        :provider

      not ladder? ->
        :stop

      stage not in @candidate_stages or reason in @terminal_reasons ->
        :stop

      stage == :develop and reason == :check_unavailable ->
        {:repair, reason, %{failed_stage: stage}}

      true ->
        {:next_rung, {class, reason}, class}
    end
  end
end
