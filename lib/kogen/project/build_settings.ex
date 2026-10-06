defmodule Kogen.Project.BuildSettings do
  @moduledoc false

  alias Kogen.Contracts.Yaml

  @ladders ~w(ladder ladder-diverse ladder-luna ladder-sol-low ladder-sol-medium ladder-sol-high)
  @recipes @ladders ++
             ~w(staged plan-shell direct direct-shell direct-escalate escalate-shell) ++
             Enum.map(@ladders, &(&1 <> "+edge"))
  @roles %{
    "builder" => :builder,
    "planner" => :planner,
    "reviewer" => :reviewer,
    "context" => :context,
    "auditor" => :auditor,
    "shaper" => :shaper
  }

  @spec parse(term()) :: {:ok, map() | nil} | {:error, [map()]}
  def parse(nil), do: {:ok, nil}

  def parse(value) when is_map(value) do
    unknown =
      unknown_keys(
        value,
        ~w(recipe roles wall_minutes edge_tests model_fallback context_bytes luna_provider_mode tool_result_tokens model_generation_tokens plan_max_words),
        "build"
      )

    parse_values(value, unknown)
  end

  def parse(_value), do: error("`build` must be a map")

  defp parse_values(value, unknown) do
    {recipe, recipe_errors} = recipe(value)
    {roles, role_errors} = roles(value)
    {wall_minutes, wall_errors} = wall_minutes(value)
    {edge_tests, edge_errors} = edge_tests(value)
    {model_fallback, fallback_errors} = model_fallback(value)
    {context_bytes, context_errors} = context_bytes(value)
    {luna_mode, luna_errors} = luna_provider_mode(value)
    {budgets, budget_errors} = budgets(value)
    {plan_max_words, plan_errors} = plan_max_words(value)

    errors =
      unknown ++
        recipe_errors ++
        role_errors ++
        wall_errors ++
        edge_errors ++
        fallback_errors ++ context_errors ++ luna_errors ++ budget_errors ++ plan_errors

    if errors == [],
      do:
        {:ok,
         Map.merge(budgets, %{
           recipe: recipe,
           roles: roles,
           wall_minutes: wall_minutes,
           edge_tests: edge_tests,
           model_fallback: model_fallback,
           context_bytes: context_bytes,
           luna_provider_mode: luna_mode,
           plan_max_words: plan_max_words
         })},
      else: {:error, errors}
  end

  @spec load_machine(Path.t()) :: {:ok, map() | nil} | {:error, [map()]}
  def load_machine(home) do
    path = Path.join([home, ".kogen", "config.yaml"])

    case File.read(path) do
      {:ok, source} -> parse_machine(source)
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> error("cannot read #{path}: #{inspect(reason)}")
    end
  end

  @spec effective(map() | nil, map() | nil) :: %{
          recipe: String.t(),
          roles: map(),
          wall_minutes: pos_integer() | nil,
          edge_tests: boolean(),
          model_fallback: boolean(),
          context_bytes: pos_integer() | nil,
          luna_provider_mode: :responses | :lite,
          tool_result_tokens: pos_integer(),
          model_generation_tokens: pos_integer() | nil,
          plan_max_words: pos_integer()
        }
  def effective(machine, project) do
    machine = machine || %{}
    project = project || %{}
    machine_roles = Map.get(machine, :roles, %{})
    project_roles = Map.get(project, :roles, %{})

    roles =
      Map.merge(machine_roles, project_roles, fn _role, machine_values, project_values ->
        Map.merge(machine_values, project_values)
      end)

    %{
      recipe: Map.get(project, :recipe) || Map.get(machine, :recipe) || "ladder",
      roles: roles,
      wall_minutes: Map.get(project, :wall_minutes) || Map.get(machine, :wall_minutes),
      edge_tests: edge_setting(project, machine),
      model_fallback: fallback_setting(project, machine),
      context_bytes: Map.get(project, :context_bytes) || Map.get(machine, :context_bytes),
      luna_provider_mode:
        Map.get(project, :luna_provider_mode) || Map.get(machine, :luna_provider_mode) ||
          :responses,
      tool_result_tokens:
        Map.get(project, :tool_result_tokens) || Map.get(machine, :tool_result_tokens) || 2_000,
      model_generation_tokens:
        Map.get(project, :model_generation_tokens) || Map.get(machine, :model_generation_tokens),
      plan_max_words:
        Map.get(project, :plan_max_words) || Map.get(machine, :plan_max_words) || 500
    }
  end

  defp parse_machine(source) do
    case Yaml.parse(source) do
      {:ok, document} when is_map(document) ->
        errors = unknown_keys(document, ["build"], "config")

        case {Map.fetch(document, "build"), errors} do
          {:error, []} -> {:ok, nil}
          {value, []} -> parse(elem(value, 1))
          {_value, errors} -> {:error, errors}
        end

      {:ok, _value} ->
        error("config.yaml must contain a map at the document root")

      {:error, issues} ->
        {:error, issues}
    end
  end

  defp recipe(value) do
    case Map.fetch(value, "recipe") do
      {:ok, recipe} when is_binary(recipe) and recipe in @recipes ->
        {recipe, []}

      {:ok, recipe} ->
        {nil,
         [
           issue(
             "build.recipe must be one of #{Enum.join(@recipes, ", ")}; got #{inspect(recipe)}"
           )
         ]}

      :error ->
        {nil, []}
    end
  end

  defp budgets(value) do
    {tool, tool_errors} = budget(value, "tool_result_tokens", 128)
    {model, model_errors} = budget(value, "model_generation_tokens", 1)
    {%{tool_result_tokens: tool, model_generation_tokens: model}, tool_errors ++ model_errors}
  end

  defp budget(value, key, minimum) do
    case Map.fetch(value, key) do
      :error -> {nil, []}
      {:ok, count} when is_integer(count) and count >= minimum and count <= 100_000 -> {count, []}
      _invalid -> {nil, [issue("build.#{key} must be an integer between #{minimum} and 100000")]}
    end
  end

  defp luna_provider_mode(value) do
    case Map.fetch(value, "luna_provider_mode") do
      {:ok, "responses"} -> {:responses, []}
      {:ok, "lite"} -> {:lite, []}
      :error -> {nil, []}
      _invalid -> {nil, [issue("build.luna_provider_mode must be responses or lite")]}
    end
  end

  defp plan_max_words(value) do
    case Map.fetch(value, "plan_max_words") do
      {:ok, words} -> parse_plan_words(words)
      :error -> {nil, []}
    end
  end

  defp parse_plan_words(words) when is_integer(words) and words in 300..2000, do: {words, []}

  defp parse_plan_words(words) when is_binary(words) do
    case Integer.parse(words) do
      {number, ""} -> parse_plan_words(number)
      _invalid -> parse_plan_words(nil)
    end
  end

  defp parse_plan_words(_invalid),
    do: {nil, [issue("build.plan_max_words must be an integer from 300 to 2000")]}

  defp context_bytes(value) do
    case Map.fetch(value, "context_bytes") do
      {:ok, bytes} when is_integer(bytes) and bytes >= 16_000 -> {bytes, []}
      {:ok, _other} -> {nil, [issue("build.context_bytes must be an integer of at least 16000")]}
      :error -> {nil, []}
    end
  end

  defp wall_minutes(value) do
    case Map.fetch(value, "wall_minutes") do
      {:ok, minutes} when is_integer(minutes) and minutes > 0 ->
        {minutes, []}

      {:ok, minutes} ->
        {nil, [issue("build.wall_minutes must be a positive integer; got #{inspect(minutes)}")]}

      :error ->
        {nil, []}
    end
  end

  # `build.edge_tests: true` turns on a ladder's edge probe, like a `+edge` recipe suffix.
  defp edge_tests(value) do
    case Map.fetch(value, "edge_tests") do
      {:ok, enabled} when enabled in [true, "true"] ->
        {true, []}

      {:ok, disabled} when disabled in [false, "false"] ->
        {false, []}

      {:ok, other} ->
        {nil, [issue("build.edge_tests must be true or false; got #{inspect(other)}")]}

      :error ->
        {nil, []}
    end
  end

  # `build.model_fallback: false` keeps provider resilience on the same model after overloads.
  defp model_fallback(value) do
    case Map.fetch(value, "model_fallback") do
      {:ok, enabled} when enabled in [true, "true"] ->
        {true, []}

      {:ok, disabled} when disabled in [false, "false"] ->
        {false, []}

      {:ok, other} ->
        {nil, [issue("build.model_fallback must be true or false; got #{inspect(other)}")]}

      :error ->
        {nil, []}
    end
  end

  defp fallback_setting(project, machine) do
    case {Map.get(project, :model_fallback), Map.get(machine, :model_fallback)} do
      {project_value, _machine} when is_boolean(project_value) -> project_value
      {nil, machine_value} -> machine_value != false
    end
  end

  defp edge_setting(project, machine) do
    case {Map.get(project, :edge_tests), Map.get(machine, :edge_tests)} do
      {project_value, _machine} when is_boolean(project_value) -> project_value
      {nil, machine_value} -> machine_value == true
    end
  end

  defp roles(value) do
    case Map.fetch(value, "roles") do
      {:ok, role_values} when is_map(role_values) -> parse_roles(role_values)
      {:ok, _role_values} -> {%{}, [issue("build.roles must be a map of role settings")]}
      :error -> {%{}, []}
    end
  end

  defp parse_roles(values) do
    Enum.reduce(values, {%{}, []}, fn {name, fields}, {roles, errors} ->
      cond do
        not Map.has_key?(@roles, name) ->
          {roles, errors ++ [issue("build.roles has unknown role #{inspect(name)}")]}

        not is_map(fields) ->
          {roles, errors ++ [issue("build.roles.#{name} must be a map")]}

        true ->
          {settings, field_errors} = role_settings(name, fields)
          {Map.put(roles, Map.fetch!(@roles, name), settings), errors ++ field_errors}
      end
    end)
  end

  defp role_settings(role, fields) do
    unknown = unknown_keys(fields, ~w(model effort), "build.roles.#{role}")
    {model, model_errors} = optional_setting(fields, "model", role)
    {effort, effort_errors} = optional_setting(fields, "effort", role)
    settings = Enum.reject([model: model, effort: effort], fn {_key, value} -> is_nil(value) end)
    {Map.new(settings), unknown ++ model_errors ++ effort_errors}
  end

  defp optional_setting(fields, key, role) do
    case Map.fetch(fields, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {value, []}

      {:ok, value} ->
        {nil,
         [issue("build.roles.#{role}.#{key} must be a non-empty string, got #{inspect(value)}")]}

      :error ->
        {nil, []}
    end
  end

  defp unknown_keys(map, allowed, label) do
    map
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort()
    |> Enum.map(&issue("#{label} has unknown key #{inspect(&1)}"))
  end

  defp issue(message), do: %{line: nil, message: message}
  defp error(message), do: {:error, [issue(message)]}
end
