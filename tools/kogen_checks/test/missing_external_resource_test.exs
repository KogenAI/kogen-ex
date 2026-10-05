Code.require_file("support/precision_cases.ex", __DIR__)

defmodule KogenChecks.Check.MissingExternalResourceTest do
  use Credo.Test.Case

  alias KogenChecks.Check.MissingExternalResource
  alias KogenChecks.PrecisionCases

  test "21 compile-time reads name their location and fix" do
    for {name, body} <- PrecisionCases.positives() do
      source = name |> PrecisionCases.source(body) |> to_source_file("lib/#{name}.ex")
      issues = run_check(source, MissingExternalResource, blocking: true)
      assert [issue] = issues, name
      assert issue.filename == "lib/#{name}.ex"
      assert issue.line_no >= 2
      assert issue.message =~ "Declare @external_resource"
      assert issue.exit_status != 0
    end
  end

  test "23 declared resources, inactive branches and runtime reads produce no findings" do
    for {name, body} <- PrecisionCases.negatives() do
      issues =
        name
        |> PrecisionCases.source(body)
        |> to_source_file("lib/#{name}.ex")
        |> run_check(MissingExternalResource, blocking: true)

      assert issues == [], name
    end
  end

  test "an unresolved path stays advisory" do
    "defmodule Read do\n@data File.read!(Application.app_dir(:app, \"input.txt\"))\nend"
    |> to_source_file("lib/read.ex")
    |> run_check(MissingExternalResource, blocking: true)
    |> assert_issue(fn issue -> assert issue.exit_status == 0 end)
  end
end
