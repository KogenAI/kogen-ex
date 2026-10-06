defmodule Kogen.Diagnostics.Parser.Compile do
  @moduledoc false
  import Kogen.Diagnostics.Parser.Common,
    only: [
      location: 1,
      normalize_path: 2,
      compile_rule: 1,
      symbol: 1,
      finding: 5,
      lines: 1,
      cli_line: 1
    ]

  @file_path ~r{((?:\$WORKDIR/|/)?[A-Za-z0-9_.$-]+(?:/[A-Za-z0-9_.$-]+)*\.exs?)\s*$}

  def findings(output, workdir) do
    lines = lines(output)
    explicit_findings(lines, workdir) ++ location_findings(lines, workdir)
  end

  defp explicit_findings(lines, workdir) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      clean_line = cli_line(line)

      cond do
        String.starts_with?(String.trim(clean_line), "warning:") ->
          compile_diagnostic(lines, index, "warning:", workdir)

        String.starts_with?(String.trim(clean_line), "error:") ->
          compile_diagnostic(lines, index, "error:", workdir)

        String.contains?(clean_line, "** (CompileError)") or
            String.contains?(clean_line, "** (SyntaxError)") ->
          compile_error(clean_line, workdir)

        true ->
          []
      end
    end)
  end

  defp location_findings(lines, workdir) do
    Enum.flat_map(lines, fn line ->
      case location(cli_line(line)) do
        {:ok, path, line_number, col, message} when message != "" ->
          if Regex.match?(~r/\b(?:error|warning):/i, message),
            do: [
              "compile"
              |> finding(
                compile_rule(message),
                {normalize_path(path, workdir), line_number, col},
                symbol(message),
                message
              )
              |> Map.put(
                :severity,
                severity(message)
              )
            ],
            else: []

        _other ->
          []
      end
    end)
  end

  defp compile_diagnostic(lines, index, prefix, workdir) do
    diagnostic =
      lines
      |> Enum.at(index)
      |> cli_line()
      |> String.trim()
      |> String.replace_prefix(prefix, "")
      |> String.trim()

    lines
    |> Enum.drop(index + 1)
    |> Enum.take(12)
    |> Enum.find_value(unlocated_diagnostic(diagnostic, prefix, lines, index), fn line ->
      case location(cli_line(line)) do
        {:ok, path, line_number, col, tail} ->
          message = if diagnostic == "", do: tail, else: diagnostic

          [
            "compile"
            |> finding(
              compile_rule(message),
              {normalize_path(path, workdir), line_number, col},
              diagnostic_symbol(message, tail),
              message
            )
            |> Map.put(:severity, severity(prefix))
            |> Map.put(:explanation, diagnostic_details(lines, index))
          ]

        _other ->
          nil
      end
    end)
  end

  defp unlocated_diagnostic(message, prefix, lines, index) do
    [
      "compile"
      |> finding(compile_rule(message), {nil, nil, nil}, symbol(message), message)
      |> Map.put(:severity, severity(prefix))
      |> Map.put(:explanation, diagnostic_details(lines, index))
    ]
  end

  defp severity(text), do: if(String.contains?(text, "warning:"), do: :warning, else: :error)

  defp diagnostic_details(lines, index) do
    lines
    |> Enum.drop(index + 1)
    |> Enum.take_while(fn line ->
      not Regex.match?(~r/^\s*(?:warning:|error:|\*\* \(|== Compilation|make(?:\[\d+\])?:)/, line)
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp diagnostic_symbol(message, tail) do
    symbol(message) || symbol(tail) || warning_symbol(message, tail)
  end

  defp warning_symbol(message, tail) do
    case Regex.run(~r/function ([a-z_][A-Za-z0-9_?!]*)\/(\d+)/, message, capture: :all_but_first) do
      [name, arity] ->
        case Regex.run(~r/([A-Z][A-Za-z0-9_.]*) \(module\)/, tail, capture: :all_but_first) do
          [module] -> "#{module}.#{name}/#{arity}"
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp compile_error(line, workdir) do
    case location(line) do
      {:ok, path, line_number, col, message} ->
        [
          finding(
            "compile",
            "compile_error",
            {normalize_path(path, workdir), line_number, col},
            symbol(message),
            message
          )
        ]

      :error ->
        case Regex.run(@file_path, line, capture: :all_but_first) do
          [path] ->
            [
              finding(
                "compile",
                "compile_error",
                {normalize_path(path, workdir), nil, nil},
                nil,
                String.trim(line)
              )
            ]

          _other ->
            []
        end
    end
  end
end
