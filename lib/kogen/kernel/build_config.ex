defmodule Kogen.Kernel.BuildConfig do
  @moduledoc false

  @spec load(Path.t(), map() | nil) :: {:ok, map()} | {:error, term()}
  def load(home, project_build) do
    with {:ok, machine} <- Kogen.Project.load_machine_build_settings(home) do
      {:ok, Kogen.Project.effective_build_settings(machine, project_build)}
    end
  end

  @spec builder_settings(map()) :: {String.t(), String.t()}
  def builder_settings(roles) do
    builder = Map.get(roles, :builder, %{})
    {Map.get(builder, :model, "gpt-6-luna"), Map.get(builder, :effort, "max")}
  end

  @spec role_overrides(map()) :: map()
  def role_overrides(roles), do: Map.delete(roles, :shaper)

  @spec shape_settings(map()) :: {String.t(), String.t()}
  def shape_settings(roles) do
    builder = builder_settings(roles)

    case Map.get(roles, :shaper) do
      nil ->
        builder

      settings ->
        {Map.get(settings, :model, elem(builder, 0)),
         Map.get(settings, :effort, elem(builder, 1))}
    end
  end
end
