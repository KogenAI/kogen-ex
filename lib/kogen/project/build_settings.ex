defmodule Kogen.Project.BuildSettings do
  @moduledoc false

  alias Kogen.Contracts.Yaml

  @ladders ~w(ladder ladder-diverse ladder-luna ladder-sol-medium)
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
    unknown = unknown_keys(value, ~w(recipe roles wall_minutes edge_tests), "build")
    {recipe, recipe_errors} = recipe(value)
    {roles, role_errors} = roles(value)
    {wall_minutes, wall_errors} = wall_minutes(value)
    {edge_tests, edge_errors} = edge_tests(value)
    errors = unknown ++ recipe_errors ++ role_errors ++ wall_errors ++ edge_errors

    if errors == [],
      do:
        {:ok, %{recipe: recipe, roles: roles, wall_minutes: wall_minutes, edge_tests: edge_tests}},
      else: {:error, errors}
  end

  def parse(_value), do: error("`build` must be a map")

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
          edge_tests: boolean()
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
      edge_tests: edge_setting(project, machine)
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
