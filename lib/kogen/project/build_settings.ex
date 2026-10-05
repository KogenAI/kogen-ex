defmodule Kogen.Project.BuildSettings do
  @moduledoc false

  alias Kogen.Contracts.Yaml

  @recipes ~w(staged plan-shell direct direct-shell direct-escalate escalate-shell)
  @roles ~w(builder planner reviewer context shaper)

  @spec parse(term()) :: {:ok, map() | nil} | {:error, [map()]}
  def parse(nil), do: {:ok, nil}

  def parse(value) when is_map(value) do
    unknown = unknown_keys(value, ~w(recipe roles), "build")
    {recipe, recipe_errors} = recipe(value)
    {roles, role_errors} = roles(value)
    errors = unknown ++ recipe_errors ++ role_errors
    if errors == [], do: {:ok, %{recipe: recipe, roles: roles}}, else: {:error, errors}
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

  @spec effective(map() | nil, map() | nil) :: %{recipe: String.t(), roles: map()}
  def effective(machine, project) do
    machine = machine || %{}
    project = project || %{}
    machine_roles = Map.get(machine, :roles, %{})
    project_roles = Map.get(project, :roles, %{})

    roles =
      Map.merge(machine_roles, project_roles, fn _role, machine_values, project_values ->
        Map.merge(machine_values, project_values)
      end)

    %{recipe: Map.get(project, :recipe) || Map.get(machine, :recipe) || "staged", roles: roles}
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
        name not in @roles ->
          {roles, errors ++ [issue("build.roles has unknown role #{inspect(name)}")]}

        not is_map(fields) ->
          {roles, errors ++ [issue("build.roles.#{name} must be a map")]}

        true ->
          {settings, field_errors} = role_settings(name, fields)
          {Map.put(roles, String.to_existing_atom(name), settings), errors ++ field_errors}
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
