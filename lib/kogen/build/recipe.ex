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
  verbatim Request and the acceptance tests, plus the Intent's Acceptance items when
  `acceptance_items` is set.
  """
  @type rung :: %{
          required(:name) => String.t(),
          required(:builder) => :builder | {String.t(), String.t()},
          required(:input) => :plan | :raw_request,
          optional(:acceptance_items) => boolean(),
          optional(:experimental) => boolean()
        }

  @typedoc """
  Rungs run in order until one Candidate is green. When the planner rates the task hard, the
  first `parallel_on_hard` rungs run at once (with `on_hard: :skip_first` the Build starts at
  the second rung instead). Each rung repairs while its failure count falls,
  at most `repair_cap` times; `wall_ms` bounds the whole Build. After the last rung, fresh
  attempts cycle through the rungs from index `repeat_from` (named `<rung>-2`, `<rung>-3`, ...)
  until the budget is spent; `repeat_from: nil` ends the ladder after its last rung. A usage
  limit or lost login pauses the Build for `pause_ms` at a time, outside the budget, for at
  most `pause_cap_ms`. Rungs marked `experimental` are reported as such. When two or more
  parallel rungs are green, each runs the others' tests; `cross_check_ms` bounds that in total.
  With `edge_tests: true`, the first green Candidates also run black-box edge tests written from
  the verbatim Request before landing; `edge_ms` bounds those test runs in total.
  """
  @type ladder :: %{
          required(:rungs) => [rung()],
          required(:parallel_on_hard) => non_neg_integer(),
          required(:repair_cap) => pos_integer(),
          required(:wall_ms) => pos_integer(),
          required(:repeat_from) => non_neg_integer() | nil,
          required(:on_hard) => :parallel | :skip_first,
          required(:pause_ms) => pos_integer(),
          required(:pause_cap_ms) => pos_integer(),
          optional(:cross_check_ms) => pos_integer(),
          optional(:edge_tests) => boolean(),
          optional(:edge_ms) => pos_integer()
        }

  @type escalation :: %{
          required(:model) => String.t(),
          required(:effort) => String.t(),
          required(:on) => [atom()]
        }

  @ladder_names ["ladder", "ladder-diverse", "ladder-luna", "ladder-sol-medium"]
  @names [
           "staged",
           "plan-shell",
           "direct",
           "direct-shell",
           "direct-escalate",
           "escalate-shell"
         ] ++ @ladder_names
  @sol_high {"gpt-6.1-sol", "high"}
  @sol_medium {"gpt-6.1-sol", "medium"}
  @luna_max {"gpt-6-luna", "max"}
  @ladder_policy %{
    parallel_on_hard: 2,
    on_hard: :parallel,
    repair_cap: 6,
    wall_ms: 3_600_000,
    repeat_from: 2,
    pause_ms: 300_000,
    pause_cap_ms: 86_400_000,
    cross_check_ms: 300_000,
    edge_ms: 180_000
  }
  @edge_suffix "+edge"

  @luna_rungs [
    %{name: "builder", builder: @luna_max, input: :plan},
    %{name: "fresh-2", builder: @luna_max, input: :plan},
    %{name: "fresh-3", builder: @luna_max, input: :plan},
    %{name: "raw-request", builder: @luna_max, input: :raw_request, experimental: true}
  ]

  @staged_stages [:context, :plan, :develop, :done_gate, :fix, :check, :review, :commit, :land]
  @plan_shell_stages [:plan, :develop, :done_gate, :fix, :check, :commit, :land]
  @direct_stages [:develop, :done_gate, :fix, :check, :commit, :land]

  @doc """
  The named recipe. A `+edge` suffix (for example `ladder-luna+edge`) turns on the ladder's edge
  probe; recipes without a ladder ignore it.
  """
  @spec for_build(String.t(), String.t(), String.t()) :: t()
  def for_build(name, builder_model, builder_effort) when is_binary(name) do
    if String.ends_with?(name, @edge_suffix) do
      name
      |> String.replace_suffix(@edge_suffix, "")
      |> recipe(builder_model, builder_effort)
      |> with_edge_tests(true)
    else
      recipe(name, builder_model, builder_effort)
    end
  end

  defp recipe(name, builder_model, builder_effort)
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

      name in @ladder_names ->
        Map.put(recipe, :ladder, Map.put(@ladder_policy, :rungs, ladder_rungs(name)))

      true ->
        recipe
    end
  end

  defp stages_for("staged"), do: @staged_stages
  defp stages_for(name) when name == "plan-shell" or name in @ladder_names, do: @plan_shell_stages
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

  defp roles_for(name, builder) when name in ["ladder", "ladder-diverse"],
    do: %{planner: @sol_high, builder: builder, auditor: @sol_high}

  defp roles_for("ladder-luna", _builder), do: single_model_roles(@luna_max)
  defp roles_for("ladder-sol-medium", _builder), do: single_model_roles(@sol_medium)

  defp roles_for(_direct_recipe, builder), do: %{builder: builder}

  defp single_model_roles(model), do: %{planner: model, builder: model, auditor: model}

  # Each ladder is data. `ladder` mixes models; the single-model variants compare Kogen with a
  # direct agent on the same model: fresh attempts, the auditor and raw-request, one model.
  defp ladder_rungs("ladder") do
    [
      %{name: "builder", builder: :builder, input: :plan},
      %{name: "sol-medium", builder: @sol_medium, input: :plan},
      %{name: "sol-high", builder: @sol_high, input: :plan},
      %{name: "raw-request", builder: @sol_high, input: :raw_request, experimental: true}
    ]
  end

  # `ladder` with a diverse second rung: Sol medium builds from the Request and the Intent's
  # Acceptance section without the plan, so a hard plan's two parallel Candidates fail
  # differently.
  defp ladder_rungs("ladder-diverse") do
    List.replace_at(ladder_rungs("ladder"), 1, %{
      name: "sol-medium-raw",
      builder: @sol_medium,
      input: :raw_request,
      acceptance_items: true
    })
  end

  defp ladder_rungs("ladder-luna"), do: @luna_rungs

  defp ladder_rungs("ladder-sol-medium"), do: Enum.map(@luna_rungs, &%{&1 | builder: @sol_medium})

  defp builder_tools(name),
    do:
      if(name in ["direct-shell", "plan-shell", "escalate-shell"] or name in @ladder_names,
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
      %{rungs: rungs} when index < length(rungs) -> Enum.at(rungs, index)
      %{rungs: rungs} = ladder -> repeated_rung(rungs, Map.get(ladder, :repeat_from), index)
      nil -> nil
    end
  end

  defp repeated_rung(rungs, from, index) when is_integer(from) and from < length(rungs) do
    cycle = length(rungs) - from
    past = index - length(rungs)
    rung = Enum.at(rungs, from + rem(past, cycle))
    %{rung | name: "#{rung.name}-#{div(past, cycle) + 2}"}
  end

  defp repeated_rung(_rungs, _from, _index), do: nil

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

  @doc "Turns the ladder's edge probe on or off; recipes without a ladder are unchanged."
  @spec with_edge_tests(t(), boolean()) :: t()
  def with_edge_tests(%{ladder: ladder} = recipe, enabled) when is_boolean(enabled),
    do: %{recipe | ladder: Map.put(ladder, :edge_tests, enabled)}

  def with_edge_tests(recipe, _enabled), do: recipe

  @spec edge_tests?(t()) :: boolean()
  def edge_tests?(recipe), do: match?(%{edge_tests: true}, ladder(recipe))
end
