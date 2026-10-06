defmodule Kogen.Diagnostics do
  @moduledoc "Tool diagnostics as complete records and compact developer feedback."
  use Boundary, deps: [Kogen.Contracts], exports: []

  alias Kogen.Contracts.CheckOutput
  alias Kogen.Contracts.CommandExit
  alias Kogen.Contracts.Finding
  alias Kogen.Diagnostics.Parser, as: Parser
  alias Kogen.Diagnostics.Parser.Common
  alias Kogen.Diagnostics.Parser.CredoFailures
  alias Kogen.Diagnostics.Renderer

  @failed_test_location ~r/(?:\A|\n)\s*\d+\)\s+test\b[^\n]*\n\s*([^\s]+\.exs:\d+)/

  @usage_patterns [
    ~r/(?:unknown|unrecognized|invalid) (?:command.line )?(?:option|switch|argument)/i,
    ~r/^\s*usage:/im,
    ~r/invalid project configuration|configuration error|failed to parse .*config/i,
    ~r/No Mix.Project was found|could not find mix\.exs/i
  ]

  @type finding :: Finding.t()

  @type result :: %{
          required(:duration_ms) => non_neg_integer(),
          required(:name) => String.t(),
          required(:argv) => [String.t()],
          required(:exit_status) => integer() | nil,
          required(:timed_out) => boolean(),
          required(:output) => String.t(),
          required(:log_path) => Path.t() | nil,
          required(:tool) => String.t(),
          required(:exit_level) => 0..3,
          required(:findings) => [finding()],
          required(:dialyzer_summaries) => [String.t()],
          required(:reason) => String.t() | nil
        }

  @spec failed_test_ids(binary(), Path.t()) :: [String.t()]
  def failed_test_ids(output, workdir) do
    @failed_test_location
    |> Regex.scan(output, capture: :all_but_first)
    |> Enum.map(fn [location] -> normalize_test_id(location, workdir) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec analyze(CheckOutput.t() | map()) :: result()
  def analyze(%CheckOutput{
        name: name,
        argv: argv,
        exit_status: exit_status,
        timed_out: timed_out,
        output: output,
        log_path: log_path,
        workdir: workdir,
        duration_ms: duration_ms
      }) do
    output = Common.clean(full_output(output, log_path))
    tool = tool(argv, output)

    findings =
      Parser.findings(output, tool, workdir) ++ CredoFailures.findings(output, log_path, workdir)

    findings = if findings == [], do: fallback_findings(tool, exit_status, output), else: findings
    findings = findings |> Enum.map(&Finding.record/1) |> deduplicate()
    summaries = Parser.dialyzer_summaries(output)

    base = %{
      duration_ms: duration_ms,
      name: name,
      argv: argv,
      exit_status: exit_status,
      timed_out: timed_out,
      output: output,
      log_path: log_path,
      tool: tool,
      findings: findings,
      dialyzer_summaries: summaries
    }

    level = exit_level(base)
    Map.merge(base, %{exit_level: level, reason: environment_reason(base, level)})
  end

  def analyze(command) when is_map(command), do: analyze(struct!(CheckOutput, command))

  defdelegate gate(result, spec, paths), to: Kogen.Diagnostics.GateAssessment

  @spec overall_exit_level([map()]) :: 0..3
  def overall_exit_level(results) do
    levels = Enum.map(results, & &1.exit_level)

    cond do
      3 in levels -> 3
      1 in levels -> 1
      2 in levels -> 2
      true -> 0
    end
  end

  @spec render_model_feedback([map()]) :: String.t()
  def render_model_feedback(results), do: render_model_feedback(results, [])

  def render_model_feedback(results, changed_ranges) when is_function(changed_ranges, 0),
    do: render_model_feedback(results, changed_ranges: changed_ranges)

  def render_model_feedback(results, nil), do: render_model_feedback(results, [])

  def render_model_feedback(results, options) when is_list(options),
    do:
      results
      |> Renderer.model(options)
      |> Renderer.with_changes(Keyword.get(options, :changed_ranges))

  def dialyzer_summary(results, paths),
    do: Kogen.Diagnostics.DialyzerSummary.summarize(results, paths)

  @spec render_environment_detail([map()]) :: String.t()
  def render_environment_detail(results), do: Renderer.environment(results)

  def write_report(results, run_dir), do: Kogen.Diagnostics.Report.write(results, run_dir)

  def gate_status(results) do
    case overall_exit_level(results) do
      0 -> :pass
      3 -> :environment
      _level -> :fail
    end
  end

  defp full_output(output, path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> output
    end
  end

  defp full_output(output, _path), do: output

  defp normalize_test_id(location, workdir) do
    case String.split(location, ":", parts: 2) do
      [path, line] ->
        case Integer.parse(line) do
          {line_number, ""} when line_number > 0 ->
            expanded = Path.expand(path, workdir)
            relative = Path.relative_to(expanded, Path.expand(workdir))

            if ".." in Path.split(relative) or Path.type(relative) == :absolute,
              do: nil,
              else: "#{relative}:#{line_number}"

          _error ->
            nil
        end

      _other ->
        nil
    end
  end

  defp exit_level(%{timed_out: true}), do: 3
  defp exit_level(%{exit_status: nil}), do: 3

  defp exit_level(result) do
    cond do
      CommandExit.tool_missing?(result.exit_status) -> 3
      Enum.any?(result.findings, &(&1.rule in ["parse_timeout", "parse_failure"])) -> 1
      true -> command_exit_level(result)
    end
  end

  defp command_exit_level(%{output: output} = result) do
    cond do
      result.exit_status != 0 and genuine_findings?(result.findings) -> 1
      environment_output?(output) -> 3
      usage_output?(output) -> 2
      result.exit_status == 0 and nothing_ran?(output) -> 3
      result.exit_status == 0 -> 0
      result.findings != [] -> 1
      recognized_tool?(result.tool) -> 3
      true -> 1
    end
  end

  defp tool(argv, output) do
    case mix_task(argv) do
      "compile" -> "compile"
      "credo" -> "credo"
      "format" -> "format"
      "test" -> if(compilation_output?(output), do: "compile", else: "exunit")
      "dialyzer" -> "dialyzer"
      _other -> output_tool(output)
    end
  end

  defp compilation_output?(output),
    do:
      Regex.match?(~r/Compilation (?:error|failed)|\*\* \((?:CompileError|SyntaxError)\)/, output)

  defp mix_task(argv) do
    argv
    |> Enum.with_index()
    |> Enum.find_value(fn {arg, index} ->
      if Path.basename(arg) == "mix", do: Enum.at(argv, index + 1)
    end)
  end

  defp output_tool(output) do
    detected =
      [
        {"format", Regex.match?(~r/mix format failed|files are not formatted/i, output)},
        {"compile", compilation_output?(output)},
        {"credo", Regex.match?(~r/\[[FWC]\].*↗|Credo\.Check\./u, output)},
        {"dialyzer", String.contains?(output, "Total errors:")},
        {"exunit", Regex.match?(~r/\d+\) test\s|Running ExUnit/, output)}
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    case detected do
      [] -> "check"
      [only] -> only
      _multiple -> "mixed"
    end
  end

  defp fallback_findings(_tool, 0, _output), do: []
  defp fallback_findings(_tool, nil, _output), do: []
  defp fallback_findings("mixed", _status, _output), do: []

  defp fallback_findings(tool, _status, output) do
    cond do
      usage_output?(output) ->
        [Common.finding("mix", "usage", {nil, nil, nil}, nil, Common.first_line(output))]

      environment_output?(output) ->
        []

      recognized_tool?(tool) and failure_output?(tool, output) ->
        [Common.finding(tool, "failed", {nil, nil, nil}, nil, Common.first_line(output))]

      tool == "check" and String.trim(output) == "" ->
        [
          Common.finding(
            "check",
            "failed",
            {nil, nil, nil},
            nil,
            "check exited non-zero without output"
          )
        ]

      not recognized_tool?(tool) and String.trim(output) != "" ->
        [Common.finding("check", "failed", {nil, nil, nil}, nil, Common.first_line(output))]

      true ->
        []
    end
  end

  defp failure_output?("format", output), do: String.contains?(output, "format failed")

  defp failure_output?("credo", output),
    do: Regex.match?(~r/found \d+ (?:issue|refactoring)/i, output)

  defp failure_output?("dialyzer", output), do: Regex.match?(~r/Total errors: [1-9]/, output)

  defp failure_output?("exunit", output),
    do: Regex.match?(~r/Failed: [1-9]|Result: 0\/\d+ passed/, output)

  defp failure_output?("compile", output), do: compilation_output?(output)

  defp failure_output?(_tool, output),
    do: Regex.match?(~r/make(?:\[\d+\])?: \*\*\*|exited [1-9]/, output)

  defp deduplicate(findings) do
    Enum.uniq_by(findings, fn finding ->
      {finding.tool, finding.rule, finding.path, finding.line, finding.col, finding.symbol,
       String.downcase(String.replace(finding.message, ~r/\s+/, " "))}
    end)
  end

  defp environment_reason(_result, level) when level != 3, do: nil
  defp environment_reason(%{timed_out: true}, 3), do: "check timed out"

  defp environment_reason(%{exit_status: nil}, 3),
    do: "check could not start or returned no exit status"

  defp environment_reason(%{output: output}, 3) when output != "" do
    cond do
      Regex.match?(~r/Operation not permitted|Permission denied/i, output) ->
        "the environment denied a required operation"

      Regex.match?(~r/acceptance formatter report is (?:missing|empty|malformed)/i, output) ->
        "acceptance test evidence was unavailable"

      nothing_ran?(output) ->
        "the check collected no test results"

      Regex.match?(
        ~r/No such file or directory|(?:command|tool) (?:was )?not found|mise env failed/i,
        output
      ) ->
        "a required tool or file was unavailable"

      true ->
        "the check failed without parseable findings"
    end
  end

  defp environment_reason(_result, 3), do: "the check failed without output"

  defp environment_output?(output), do: Common.environment_text?(output)

  # A failure with a source location that is not itself environment noise is the
  # candidate's to fix, even when the same run also hit environmental trouble.
  defp genuine_findings?(findings),
    do:
      Enum.any?(findings, &(&1.severity == :error and is_binary(&1.path) and is_integer(&1.line)))

  defp usage_output?(output), do: Enum.any?(@usage_patterns, &Regex.match?(&1, output))

  defp nothing_ran?(output),
    do:
      Regex.match?(~r/nothing collected|no tests? (?:were )?collected|no tests? to run/i, output)

  defp recognized_tool?(tool),
    do: tool in ["compile", "credo", "format", "exunit", "dialyzer", "mixed"]
end
