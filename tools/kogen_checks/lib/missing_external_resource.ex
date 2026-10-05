defmodule KogenChecks.Check.MissingExternalResource do
  @moduledoc "Compile-time reads must declare the matching external resource."
  use Credo.Check,
    category: :warning,
    base_priority: :high,
    param_defaults: [blocking: true],
    explanations: [check: "Declare @external_resource for every compile-time file read."]

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), Keyword.t()) :: [Credo.Issue.t()]
  def run(source_file, params) do
    analyzer = Kogen.Quality.Source.ExternalResource
    findings = apply(analyzer, :analyze, [SourceFile.ast(source_file), source_file.filename])
    meta = IssueMeta.for(source_file, params)
    blocking? = Params.get(params, :blocking, __MODULE__)

    for {line, message, proven?} <- findings do
      format_issue(meta,
        line_no: line,
        message: message,
        trigger: Credo.Issue.no_trigger(),
        exit_status: if(blocking? and proven?, do: 16, else: 0)
      )
    end
  end
end
