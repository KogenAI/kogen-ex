defmodule Kogen.Build.Recipe do
  @moduledoc "Plain-data Build recipes and their role model settings."

  @type stage ::
          :context | :plan | :develop | :done_gate | :fix | :check | :review | :commit | :land
  @type role :: :context | :planner | :builder | :reviewer
  @type t :: %{
          required(:name) => String.t(),
          required(:stages) => [stage()],
          required(:roles) => %{required(role()) => {String.t(), String.t()}},
          required(:builder_tools) => :full | :shell
        }

  @staged_stages [:context, :plan, :develop, :done_gate, :fix, :check, :review, :commit, :land]
  @direct_stages [:develop, :done_gate, :fix, :check, :commit, :land]

  @spec for_build(String.t(), String.t(), String.t()) :: t()
  def for_build(name, builder_model, builder_effort)
      when name in ["staged", "direct", "direct-shell"] and is_binary(builder_model) and
             is_binary(builder_effort) do
    stages = if name == "staged", do: @staged_stages, else: @direct_stages
    builder = {builder_model, builder_effort}

    roles =
      case name do
        "staged" ->
          %{context: {"gpt-6-luna", "low"}, planner: builder, builder: builder, reviewer: builder}

        direct_recipe when direct_recipe in ["direct", "direct-shell"] ->
          %{builder: builder}
      end

    builder_tools = if name == "direct-shell", do: :shell, else: :full

    %{name: name, stages: stages, roles: roles, builder_tools: builder_tools}
  end

  @spec name(t()) :: String.t()
  def name(%{name: name}) when name in ["staged", "direct", "direct-shell"], do: name

  @spec stages(t()) :: [stage()]
  def stages(%{stages: stages}) when is_list(stages), do: stages

  @spec role(t(), role()) :: {String.t(), String.t()}
  def role(%{roles: roles}, role), do: Map.fetch!(roles, role)
end
