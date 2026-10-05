defmodule Kogen.Checks.Feedback.Parser.Common do
  @moduledoc false
  @message_chars 200
  @location ~r{(?<path>(?:\$WORKDIR/|/)?[A-Za-z0-9_.$-]+(?:/[A-Za-z0-9_.$-]+)*\.exs?):(?<line>\d+)(?::(?<col>\d+))?(?::(?<tail>.*))?}

  @environment_patterns [
    ~r/acceptance formatter report is (?:missing|empty|malformed)/i,
    ~r/Operation not permitted/i,
    ~r/Permission denied/i,
    ~r/No such file or directory/i,
    ~r/(?:command|tool) (?:was )?not found/i,
    ~r/mise env failed/i,
    ~r/(?:timed out|deadline reached)/i,
    ~r/nothing collected|no tests? (?:were )?collected|no tests? to run/i,
    ~r/(?:required )?fixture[s]? (?:is |are )?(?:missing|not found|unavailable)/i
  ]

  def environment_text?(text), do: Enum.any?(@environment_patterns, &Regex.match?(&1, text))

  def location(line) do
    case Regex.run(@location, cli_line(line), capture: :all_but_first) do
      [path, line] ->
        location(path, line, nil, nil)

      [path, line, part] ->
        if Regex.match?(~r/^\d+$/, part),
          do: location(path, line, part, nil),
          else: location(path, line, nil, part)

      [path, line, col, tail] ->
        location(path, line, col, tail)

      _other ->
        :error
    end
  end

  defp location(path, line, col, tail) do
    {:ok, path, int(line), int(col || "1"), String.trim(tail || "")}
  end

  def normalize_path(path, workdir) do
    cond do
      String.starts_with?(path, "$WORKDIR/") ->
        String.replace_prefix(path, "$WORKDIR/", "")

      Path.type(path) == :relative ->
        path

      Path.type(workdir) == :absolute and
          String.starts_with?(path, Path.expand(workdir) <> "/") ->
        Path.relative_to(path, Path.expand(workdir))

      true ->
        case Enum.find_index(Path.split(path), &(&1 in ["lib", "test", "src"])) do
          nil -> Path.basename(path)
          index -> path |> Path.split() |> Enum.drop(index) |> Path.join()
        end
    end
  end

  def credo_symbol(line) do
    case Regex.run(~r/#\(([^)]+)\)/, line, capture: :all_but_first) do
      [symbol] -> symbol
      _other -> nil
    end
  end

  def credo_rule(message) do
    cond do
      match = Regex.run(~r/(?:Credo\.Check\.|Warning\.)([A-Z][A-Za-z0-9_.]+)/, message) ->
        Enum.at(match, 1)

      String.contains?(message, "spans ") ->
        "ModuleSize"

      String.contains?(message, "File has ") ->
        "FileSize"

      true ->
        "finding"
    end
  end

  def credo_severity("F"), do: :error
  def credo_severity("W"), do: :warning
  def credo_severity(_severity), do: :note

  def compile_rule(message) do
    cond do
      String.contains?(message, "undefined or private") -> "undefined"
      String.contains?(message, "undefined function") -> "undefined"
      String.contains?(message, "deprecated") -> "deprecated"
      String.contains?(message, "unused") -> "unused"
      true -> "compile_error"
    end
  end

  def symbol(message) do
    case Regex.run(
           ~r/\b([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\.[a-z_][A-Za-z0-9_?!]*\/\d+)\b/,
           message,
           capture: :all_but_first
         ) do
      [name] -> name
      _other -> nil
    end
  end

  def finding(tool, rule, {path, line, col}, symbol, message) do
    %{
      tool: tool,
      rule: rule,
      severity: :error,
      path: path,
      line: line,
      col: col,
      symbol: symbol,
      message: truncate(String.replace(message, ~r/\s+/, " "))
    }
  end

  def first_line(output),
    do: output |> lines() |> List.first() |> Kernel.||("check failed") |> String.trim()

  def cli_line(line) do
    line
    |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/, "")
    |> String.trim_leading()
    |> String.trim_leading("┃")
    |> String.trim_leading("│")
    |> String.trim_leading("└─")
    |> String.trim()
  end

  def clean(output) when is_binary(output), do: if(String.valid?(output), do: output, else: "")
  def clean(_output), do: ""

  def lines(output), do: String.split(output, "\n")
  def int(value) when value in [nil, ""], do: 1
  def int(value), do: String.to_integer(value)

  def truncate(value, limit \\ @message_chars) do
    value = value |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(value) > limit, do: String.slice(value, 0, limit - 1) <> "…", else: value
  end
end
