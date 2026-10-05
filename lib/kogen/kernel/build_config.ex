defmodule Kogen.Kernel.BuildConfig do
  @moduledoc false

  @doc """
  The effective Build settings. `KOGEN_BENCH_NO_FALLBACK=1` turns model fallback off, whatever the
  project or machine configuration says.
  """
  @spec load(Path.t(), map() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def load(home, project_build, no_fallback \\ System.get_env("KOGEN_BENCH_NO_FALLBACK")) do
    with {:ok, machine} <- Kogen.Project.load_machine_build_settings(home) do
      settings = Kogen.Project.effective_build_settings(machine, project_build)

      if no_fallback == "1",
        do: {:ok, %{settings | model_fallback: false}},
        else: {:ok, settings}
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
        {"gpt-6.1-sol", "high"}

      settings ->
        {Map.get(settings, :model, elem(builder, 0)),
         Map.get(settings, :effort, elem(builder, 1))}
    end
  end
end
