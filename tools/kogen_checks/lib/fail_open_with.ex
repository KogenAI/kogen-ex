defmodule KogenChecks.Check.FailOpenWith do
  @moduledoc """
  Flags error branches that turn failures into success-shaped values.

  A `with ... else` branch that maps an unexpected failure to a success shape fails the gate.
  A `case` clause that maps `{:error, reason}` to a literal success default is an advisory:
  it stays visible under `--strict` and never changes the exit status.
  """
  use Credo.Check,
    category: :warning,
    base_priority: :high,
    param_defaults: [included_paths: ["lib/"]],
    explanations: [
      check: "Match the errors a `with` can produce or let the unmatched value propagate."
    ]

  @log_functions [
    :alert,
    :critical,
    :debug,
    :emergency,
    :error,
    :info,
    :log,
    :notice,
    :warn,
    :warning
  ]

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), Keyword.t()) :: [Credo.Issue.t()]
  def run(%SourceFile{filename: filename} = source_file, params) do
    if included?(filename, Params.get(params, :included_paths, __MODULE__)) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &walk(&1, &2, issue_meta))
    else
      []
    end
  end

  defp included?(filename, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      String.starts_with?(filename, prefix) or String.contains?(filename, "/" <> prefix)
    end)
  end

  defp walk({:with, meta, args} = node, issues, issue_meta) when is_list(args) and args != [] do
    case List.last(args) do
      keywords when is_list(keywords) ->
        {node, check_else(Keyword.get(keywords, :else), meta, issue_meta) ++ issues}

      _ ->
        {node, issues}
    end
  end

  defp walk({:case, meta, args} = node, issues, issue_meta) when is_list(args) do
    clauses = args |> List.last() |> Keyword.get(:do)
    {node, check_case(clauses, meta, issue_meta) ++ issues}
  end

  defp walk(node, issues, _issue_meta), do: {node, issues}

  defp check_else(nil, _meta, _issue_meta), do: []

  defp check_else(clauses, meta, issue_meta) when is_list(clauses) do
    arrows = for {:->, _, [[pattern], body]} <- clauses, do: {pattern, body}

    if Enum.any?(arrows, &fail_open?/1) do
      [with_issue(issue_meta, meta[:line])]
    else
      []
    end
  end

  defp check_else(_clauses, _meta, _issue_meta), do: []

  defp check_case(clauses, meta, issue_meta) when is_list(clauses) do
    arrows = for {:->, _, [[pattern], body]} <- clauses, do: {pattern, body}

    if Enum.any?(arrows, &error_to_default?/1) do
      [case_advisory(issue_meta, meta[:line])]
    else
      []
    end
  end

  defp check_case(_clauses, _meta, _issue_meta), do: []

  defp with_issue(issue_meta, line_no) do
    format_issue(issue_meta,
      message:
        "with/else maps an unexpected failure to a success-shaped value. Match real error shapes or drop `else`.",
      trigger: "with",
      line_no: line_no
    )
  end

  # Advisory only: low priority and exit status 0, so it is shown but never fails the gate.
  defp case_advisory(issue_meta, line_no) do
    format_issue(issue_meta,
      message:
        "An error branch drops its reason and returns a success default. Log, propagate, or re-raise the error.",
      trigger: "case",
      line_no: line_no,
      priority: Credo.Priority.to_integer(:low),
      exit_status: 0
    )
  end

  defp fail_open?({pattern, body}) do
    catch_all_failure?(pattern, last(body)) or error_to_literal?(pattern, last(body))
  end

  defp catch_all_failure?(pattern, result) do
    catch_all?(pattern) and not same_value?(pattern, result) and not error_result?(result)
  end

  defp error_to_literal?(pattern, result) do
    with_error_pattern?(pattern) and with_literal?(result)
  end

  defp error_to_default?({pattern, body}) do
    error_pattern?(pattern) and not logs?(body) and default_value?(last(body))
  end

  defp catch_all?({name, _, context}) when is_atom(name) and is_atom(context), do: true

  defp catch_all?(_pattern), do: false

  defp with_error_pattern?({:error, _}), do: true
  defp with_error_pattern?({:{}, _, [:error | _]}), do: true
  defp with_error_pattern?([{:error, _} | _]), do: true
  defp with_error_pattern?(_pattern), do: false

  defp with_literal?(value) when value in [nil, true, false, :ok, [], ""] or is_number(value),
    do: true

  defp with_literal?({:ok, value}), do: with_literal?(value)
  defp with_literal?({:%{}, _, []}), do: true
  defp with_literal?(_value), do: false

  defp error_pattern?({:error, reason}), do: variable?(reason)
  defp error_pattern?({:{}, _, [:error, reason]}), do: variable?(reason)
  defp error_pattern?(_pattern), do: false

  defp variable?({name, _, context}) when is_atom(name) and is_atom(context), do: true
  defp variable?(_pattern), do: false

  defp same_value?({name, _, context}, {name, _, result_context})
       when is_atom(name) and is_atom(context) and is_atom(result_context), do: true

  defp same_value?(_pattern, _result), do: false

  defp error_result?({:error, _}), do: true
  defp error_result?({:{}, _, [:error | _]}), do: true
  defp error_result?(:error), do: true
  defp error_result?({:halt, result}), do: error_result?(result)

  defp error_result?({function, _, _}) when function in [:raise, :reraise, :throw, :exit],
    do: true

  defp error_result?(_result), do: false

  defp default_value?(:ok), do: true
  defp default_value?({:ok, value}), do: literal?(value)
  defp default_value?({:{}, _, [:ok, value]}), do: literal?(value)
  defp default_value?(value) when value in [nil, false, []], do: true
  defp default_value?({:%{}, _, []}), do: true
  defp default_value?(_value), do: false

  defp literal?(value) when is_atom(value) or is_binary(value) or is_number(value), do: true
  defp literal?([]), do: true
  defp literal?([head | tail]), do: literal?(head) and literal?(tail)
  defp literal?({:{}, _, values}), do: Enum.all?(values, &literal?/1)

  defp literal?({:%{}, _, entries}) do
    Enum.all?(entries, fn
      {key, value} -> literal?(key) and literal?(value)
      _entry -> false
    end)
  end

  defp literal?(_value), do: false

  defp logs?(body) do
    {_body, found?} = Macro.prewalk(body, false, &find_log/2)
    found?
  end

  defp find_log(node, found?) do
    {node, found? or log_call?(node)}
  end

  defp log_call?({{:., _, [module, function]}, _, _}) when function in @log_functions do
    module == :logger or logger_alias?(module)
  end

  defp log_call?(_node), do: false

  defp logger_alias?({:__aliases__, _, parts}) when is_list(parts),
    do: List.last(parts) == :Logger

  defp logger_alias?(_module), do: false

  defp last({:__block__, _, expressions}) when expressions != [], do: List.last(expressions)
  defp last(expression), do: expression
end
