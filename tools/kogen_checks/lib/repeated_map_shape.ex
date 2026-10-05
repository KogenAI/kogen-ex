defmodule KogenChecks.Check.RepeatedMapShape do
  @moduledoc "Repeated public bare-map contracts are advisory struct candidates."
  use Credo.Check,
    category: :refactor,
    base_priority: :low,
    explanations: [check: "Use a struct for a repeated public map with at least four atom keys."]

  @impl Credo.Check
  @spec run_on_all_source_files(Credo.Execution.t(), [Credo.SourceFile.t()], Keyword.t()) :: :ok
  def run_on_all_source_files(exec, source_files, params) do
    sources = Enum.map(source_files, &{&1.filename, SourceFile.ast(&1)})
    files = Map.new(source_files, &{&1.filename, &1})
    analyzer = Kogen.Quality.Source.MapShapes

    for {file, line, message} <- apply(analyzer, :analyze, [sources]) do
      issue =
        format_issue(IssueMeta.for(Map.fetch!(files, file), params),
          line_no: line,
          message: message,
          trigger: "%{",
          exit_status: 0
        )

      Credo.Execution.ExecutionIssues.append(exec, issue)
    end

    :ok
  end

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), Keyword.t()) :: [Credo.Issue.t()]
  def run(_source_file, _params), do: []
end
