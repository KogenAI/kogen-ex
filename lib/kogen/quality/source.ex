defmodule Kogen.Quality.Source do
  @moduledoc "The gate and Credo adapters share these deterministic source checks."
  alias Kogen.Quality.Report
  alias Kogen.Quality.Request
  alias Kogen.Quality.Source.ExternalResource
  alias Kogen.Quality.Source.MapShapes

  @spec run(Request.t()) :: [map()]
  def run(request) do
    if File.regular?(Path.join(request.workdir, "mix.exs")) do
      {sources, notes} = sources(request.workdir)
      resources = Enum.flat_map(sources, &resource_findings(&1, request.workdir))

      maps =
        for {file, line, message} <- MapShapes.analyze(sources),
            do: Report.finding("kogen_checks", "RepeatedMapShape", file, line, message)

      [Report.command("source_checks", resources ++ maps ++ notes)]
    else
      []
    end
  end

  defp sources(root) do
    ["lib", "test"]
    |> Enum.flat_map(&Path.wildcard(Path.join([root, &1, "**/*.{ex,exs}"])))
    |> Enum.sort()
    |> Enum.reduce({[], []}, fn absolute, {sources, notes} ->
      file = Path.relative_to(absolute, root)

      case parse(absolute) do
        {:ok, ast} ->
          {[{file, ast} | sources], notes}

        {:error, _reason} ->
          note =
            Report.finding(
              "kogen_checks",
              "skipped",
              file,
              1,
              "Source could not be parsed; run the project's compile check.",
              :note
            )

          {sources, [note | notes]}
      end
    end)
  end

  defp parse(file) do
    with {:ok, source} <- File.read(file),
         do: Code.string_to_quoted(source, columns: true)
  end

  defp resource_findings({file, ast}, root) do
    for {line, message, proven?} <- ExternalResource.analyze(ast, Path.join(root, file)) do
      # Promotion requires the precision evidence recorded with this check.
      severity = if proven?, do: :error, else: :warning
      Report.finding("kogen_checks", "MissingExternalResource", file, line, message, severity)
    end
  end
end
