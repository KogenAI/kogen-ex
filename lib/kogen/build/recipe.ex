defmodule Kogen.Build.Recipe do
  @moduledoc "Plain-data Build recipes and their role model settings."

  @type stage ::
          :context | :plan | :develop | :done_gate | :fix | :check | :review | :commit | :land
  @type role :: :context | :planner | :builder | :reviewer
  @type t :: %{
          required(:name) => String.t(),
          required(:stages) => [stage()],
          required(:roles) => %{required(role()) => {String.t(), String.t()}},
          required(:builder_tools) => :full | :shell,
          optional(:escalation) => escalation() | nil
        }

  @type escalation :: %{
          required(:model) => String.t(),
          required(:effort) => String.t(),
          required(:on) => [atom()]
        }

  @staged_stages [:context, :plan, :develop, :done_gate, :fix, :check, :review, :commit, :land]
  @plan_shell_stages [:plan, :develop, :done_gate, :fix, :check, :commit, :land]
  @direct_stages [:develop, :done_gate, :fix, :check, :commit, :land]

  @spec for_build(String.t(), String.t(), String.t()) :: t()
  def for_build(name, builder_model, builder_effort)
      when name in [
             "staged",
             "plan-shell",
             "direct",
             "direct-shell",
             "direct-escalate",
             "escalate-shell"
           ] and is_binary(builder_model) and is_binary(builder_effort) do
    builder = {builder_model, builder_effort}

    recipe = %{
      name: name,
      stages: stages_for(name),
      roles: roles_for(name, builder),
      builder_tools: builder_tools(name)
    }

    if name in ["direct-escalate", "escalate-shell"] do
      Map.put(recipe, :escalation, %{
        model: "gpt-6.1-sol",
        effort: "high",
        on: [:repair_cap, :unchanged, :gate_red, :turn_cap, :wall_cap]
      })
    else
      recipe
    end
  end

  defp stages_for("staged"), do: @staged_stages
  defp stages_for("plan-shell"), do: @plan_shell_stages
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

  defp roles_for(_direct_recipe, builder), do: %{builder: builder}

  defp builder_tools(name),
    do: if(name in ["direct-shell", "plan-shell", "escalate-shell"], do: :shell, else: :full)

  @spec name(t()) :: String.t()
  def name(%{name: name})
      when name in [
             "staged",
             "plan-shell",
             "direct",
             "direct-shell",
             "direct-escalate",
             "escalate-shell"
           ], do: name

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
end
