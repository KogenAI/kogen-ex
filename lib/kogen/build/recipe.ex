defmodule Kogen.Build.Recipe do
  @moduledoc "Plain-data Build recipes and their role model settings."

  @type stage ::
          :context | :plan | :develop | :done_gate | :fix | :check | :review | :commit | :land
  @type role :: :context | :planner | :builder | :reviewer | :auditor
  @type t :: %{
          required(:name) => String.t(),
          required(:stages) => [stage()],
          required(:roles) => %{required(role()) => {String.t(), String.t()}},
          required(:builder_tools) => :full | :shell,
          optional(:escalation) => escalation() | nil,
          optional(:ladder) => ladder()
        }

  @typedoc """
  One ladder rung: a fresh Candidate built by `builder` (`:builder` is the configured builder
  role). `:plan` rungs receive the planner's plan; `:raw_request` rungs receive only the
  verbatim Request and the acceptance tests.
  """
  @type rung :: %{
          required(:name) => String.t(),
          required(:builder) => :builder | {String.t(), String.t()},
          required(:input) => :plan | :raw_request
        }

  @typedoc """
  Rungs run in order until one Candidate is green. When the planner rates the task hard, the
  first `parallel_on_hard` rungs run at once. Each rung repairs while its failure count falls,
  at most `repair_cap` times; `wall_ms` bounds the whole Build.
  """
  @type ladder :: %{
          required(:rungs) => [rung()],
          required(:parallel_on_hard) => non_neg_integer(),
          required(:repair_cap) => pos_integer(),
          required(:wall_ms) => pos_integer()
        }

  @type escalation :: %{
          required(:model) => String.t(),
          required(:effort) => String.t(),
          required(:on) => [atom()]
        }

  @names [
    "staged",
    "plan-shell",
    "direct",
    "direct-shell",
    "direct-escalate",
    "escalate-shell",
    "ladder"
  ]
  @sol_high {"gpt-6.1-sol", "high"}
  @ladder %{
    rungs: [
      %{name: "builder", builder: :builder, input: :plan},
      %{name: "sol-medium", builder: {"gpt-6.1-sol", "medium"}, input: :plan},
      %{name: "sol-high", builder: @sol_high, input: :plan},
      %{name: "raw-request", builder: @sol_high, input: :raw_request}
    ],
    parallel_on_hard: 2,
    repair_cap: 6,
    wall_ms: 3_600_000
  }

  @staged_stages [:context, :plan, :develop, :done_gate, :fix, :check, :review, :commit, :land]
  @plan_shell_stages [:plan, :develop, :done_gate, :fix, :check, :commit, :land]
  @direct_stages [:develop, :done_gate, :fix, :check, :commit, :land]

  @spec for_build(String.t(), String.t(), String.t()) :: t()
  def for_build(name, builder_model, builder_effort)
      when name in @names and is_binary(builder_model) and is_binary(builder_effort) do
    builder = {builder_model, builder_effort}

    recipe = %{
      name: name,
      stages: stages_for(name),
      roles: roles_for(name, builder),
      builder_tools: builder_tools(name)
    }

    cond do
      name in ["direct-escalate", "escalate-shell"] ->
        Map.put(recipe, :escalation, %{
          model: "gpt-6.1-sol",
          effort: "high",
          on: [:repair_cap, :unchanged, :gate_red, :turn_cap, :wall_cap]
        })

      name == "ladder" ->
        Map.put(recipe, :ladder, @ladder)

      true ->
        recipe
    end
  end

  defp stages_for("staged"), do: @staged_stages
  defp stages_for(name) when name in ["plan-shell", "ladder"], do: @plan_shell_stages
  defp stages_for(_direct_recipe), do: @direct_stages

  defp roles_for("staged", builder) do
    %{
      context: {"gpt-6-luna", "low"},
      planner: {"gpt-6.1-sol", "high"},
      builder: builder,
      reviewer: {"gpt-6.1-sol", "high"}
    }
  end

  defp roles_for("plan-shell", builder), do: %{planner: {"gpt-6.1-sol", "high"}, builder: builder}

  defp roles_for("ladder", builder),
    do: %{planner: @sol_high, builder: builder, auditor: @sol_high}

  defp roles_for(_direct_recipe, builder), do: %{builder: builder}

  defp builder_tools(name),
    do:
      if(name in ["direct-shell", "plan-shell", "escalate-shell", "ladder"],
        do: :shell,
        else: :full
      )

  @spec name(t()) :: String.t()
  def name(%{name: name}) when name in @names, do: name

  @spec stages(t()) :: [stage()]
  def stages(%{stages: stages}) when is_list(stages), do: stages

  @spec role(t(), role()) :: {String.t(), String.t()}
  def role(%{roles: roles}, role), do: Map.fetch!(roles, role)

  @spec role_settings(t()) :: %{role() => %{model: String.t(), effort: String.t()}}
  def role_settings(%{roles: roles}) do
    Map.new(roles, fn {role, {model, effort}} ->
      {role, %{model: model, effort: effort}}
    end)
  end

  @spec escalation(t()) :: escalation() | nil
  def escalation(%{escalation: value}), do: value
  def escalation(_recipe), do: nil

  @spec ladder(t()) :: ladder() | nil
  def ladder(%{ladder: %{rungs: [_ | _]} = ladder}), do: ladder
  def ladder(_recipe), do: nil

  @doc "The rung at `index`, or nil past the last rung or without a ladder."
  @spec rung(t(), non_neg_integer()) :: rung() | nil
  def rung(recipe, index) when is_integer(index) and index >= 0 do
    case ladder(recipe) do
      %{rungs: rungs} -> Enum.at(rungs, index)
      nil -> nil
    end
  end

  @doc "The Build attempt name of a rung: the first rung keeps `:builder`."
  @spec rung_attempt(t(), non_neg_integer()) :: :builder | String.t()
  def rung_attempt(_recipe, 0), do: :builder

  def rung_attempt(recipe, index) do
    case rung(recipe, index) do
      %{name: name} -> name
      nil -> :builder
    end
  end

  @spec rung_builder(t(), rung()) :: {String.t(), String.t()}
  def rung_builder(recipe, %{builder: :builder}), do: role(recipe, :builder)
  def rung_builder(_recipe, %{builder: {model, effort}}), do: {model, effort}

  @spec auditor(t()) :: {String.t(), String.t()} | nil
  def auditor(%{roles: roles}), do: Map.get(roles, :auditor)

  @doc "Sets the ladder's whole-Build wall budget; recipes without a ladder are unchanged."
  @spec with_wall_ms(t(), pos_integer() | nil) :: t()
  def with_wall_ms(%{ladder: ladder} = recipe, wall_ms) when is_integer(wall_ms) and wall_ms > 0,
    do: %{recipe | ladder: %{ladder | wall_ms: wall_ms}}

  def with_wall_ms(recipe, _wall_ms), do: recipe
end
