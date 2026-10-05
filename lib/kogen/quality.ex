defmodule Kogen.Quality do
  @moduledoc "Optional Elixir quality advice scoped to a Build's base."
  use Boundary, deps: [Kogen.Contracts, Kogen.Proc, Kogen.Workspace], exports: [Request]

  alias Kogen.Quality.Analysis
  alias Kogen.Quality.Request

  @spec commands(Request.t()) :: [map()]
  def commands(%Request{base: nil}), do: []
  def commands(%Request{} = request), do: Analysis.run(request)

  @spec augment(tuple(), Path.t(), Path.t(), map(), map() | struct() | nil) :: tuple()
  def augment({:ok, result}, workdir, run_dir, env, options) when is_map(options) do
    commands = commands(Request.new(workdir, run_dir, env, options))
    checks = result.checks ++ commands
    errors = Enum.filter(commands, &(&1.exit_level > 0))
    warnings = Enum.flat_map(commands, & &1.warnings)

    feedback =
      [result.feedback | Enum.map(commands, & &1.output)] |> Enum.join("\n") |> String.trim()

    status = if errors == [], do: result.status, else: failed(result.status, errors)

    {:ok,
     %{
       result
       | checks: checks,
         status: status,
         feedback: feedback,
         warnings: result.warnings ++ warnings,
         exit_levels: result.exit_levels ++ Enum.map(commands, &{&1.name, &1.exit_level})
     }}
  end

  def augment(result, _workdir, _run_dir, _env, _options), do: result

  defp failed(:pass, errors), do: {:fail, Enum.map(errors, & &1.name)}
  defp failed({:fail, names}, errors), do: {:fail, names ++ Enum.map(errors, & &1.name)}
end
