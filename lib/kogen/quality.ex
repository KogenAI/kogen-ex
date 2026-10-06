defmodule Kogen.Quality do
  @moduledoc "Deterministic Elixir gate checks and optional advice scoped to a Build's base."
  use Boundary,
    deps: [Kogen.Contracts, Kogen.Proc, Kogen.Workspace],
    exports: [TestReach, Request, Source.ExternalResource, Source.MapShapes]

  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Quality.Analysis
  alias Kogen.Quality.Request
  alias Kogen.Quality.Source

  @spec commands(Request.t()) :: [map()]
  def commands(%Request{base: nil} = request), do: Source.run(request)
  def commands(%Request{} = request), do: Source.run(request) ++ Analysis.run(request)

  @spec augment(tuple(), Path.t(), Path.t(), map(), map() | struct() | nil) :: tuple()
  def augment({:ok, result}, workdir, run_dir, env, options) do
    options = if is_map(options), do: options, else: %{}

    commands =
      workdir
      |> Request.new(run_dir, env, options)
      |> commands()
      |> Enum.map(&CheckBaseline.annotate(&1, Map.get(options, :check_baseline, [])))

    checks = result.checks ++ commands
    errors = Enum.filter(commands, &(&1.exit_level > 0 and not &1.base_red?))
    warnings = Enum.flat_map(commands, &(&1.warnings ++ CheckBaseline.warning(&1)))

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
