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

  @spec builder_settings(map(), atom()) :: {String.t(), String.t()}
  def builder_settings(roles, provider \\ :chatgpt) do
    builder = Map.get(roles, :builder, %{})

    {Map.get(builder, :model, default_builder(provider)),
     Map.get(builder, :effort, default_effort(provider))}
  end

  @spec role_overrides(map()) :: map()
  def role_overrides(roles), do: Map.delete(roles, :shaper)

  @spec shape_settings(map(), atom()) :: {String.t(), String.t()}
  def shape_settings(roles, provider \\ :chatgpt) do
    settings = Map.get(roles, :shaper, %{})
    {Map.get(settings, :model, default_shaper(provider)), Map.get(settings, :effort, "high")}
  end

  defp default_builder(:grok), do: "grok-4.6"
  defp default_builder(_provider), do: "gpt-6-luna"
  defp default_effort(:grok), do: "high"
  defp default_effort(_provider), do: "max"
  defp default_shaper(:grok), do: "grok-4.6"
  defp default_shaper(_provider), do: "gpt-6.1-sol"
end
