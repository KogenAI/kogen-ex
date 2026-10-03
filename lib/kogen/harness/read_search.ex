defmodule Kogen.Harness.ReadSearch do
  @moduledoc false

  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Command
  alias Kogen.Harness.Error
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Paths
  alias Kogen.Harness.ToolResult

  @max_lines 400
  @max_results 200

  @spec run(Opts.t(), ToolCall.t()) :: ToolResult.t()
  def run(opts, %ToolCall{name: name} = call) when name in ["read", "search"] do
    case Codec.decode_tool_call(call) do
      {:ok, arguments} ->
        if name == "read", do: read(opts, arguments), else: search(opts, arguments)

      {:error, _reason} ->
        result("ERROR: Tool arguments do not match the schema.", true, [])
    end
  end

  defp read(opts, arguments) do
    offset = arguments.offset || 1
    limit = arguments.limit || 200

    cond do
      offset < 1 ->
        result("ERROR: offset must be a positive line number.", true, [])

      limit < 1 or limit > @max_lines ->
        result("ERROR: limit must be between 1 and 400.", true, [])

      true ->
        read_path(opts, arguments.path, offset, limit)
    end
  end

  defp read_path(opts, path, offset, limit) do
    with {:ok, absolute, relative} <- Paths.safe(opts, path),
         {:ok, contents} <- File.read(absolute),
         true <- String.valid?(contents) do
      numbered_lines(contents, relative, offset, limit)
    else
      {:error, %Error{} = error} -> result("ERROR: " <> error.detail, true, [])
      {:error, :enoent} -> result("ERROR: File does not exist.", true, [])
      {:error, reason} -> result("ERROR: File could not be read: #{inspect(reason)}", true, [])
      false -> result("ERROR: File is binary or is not UTF-8 text.", true, [])
    end
  end

  defp numbered_lines(contents, relative, offset, limit) do
    all_lines = String.split(contents, "\n", trim: false)
    selected = all_lines |> Enum.drop(offset - 1) |> Enum.take(limit)
    start_line = offset
    finish_line = start_line + length(selected) - 1
    numbered = selected |> Enum.with_index(start_line) |> Enum.map_join("\n", &line_text/1)

    continuation =
      if finish_line < length(all_lines),
        do: "\n[continue with offset=#{finish_line + 1}]",
        else: ""

    text = "#{relative}:\n#{numbered}#{continuation}"
    result(text, false, [relative])
  end

  defp line_text({line, number}), do: "#{number}: #{line}"

  defp search(opts, arguments) do
    if arguments.pattern == "" do
      result("ERROR: pattern must not be empty.", true, [])
    else
      search_path(opts, arguments.pattern, arguments.path || ".")
    end
  end

  defp search_path(opts, pattern, path) do
    case Paths.safe(opts, path) do
      {:ok, _absolute, relative} ->
        result = rg(opts, pattern, relative)

        case result do
          {:error, %Error{reason: :command_missing}} ->
            opts |> grep(pattern, relative) |> search_result()

          {:ok, %ProcResult{exit_status: 127, output_tail: output}} ->
            if missing_rg?(output),
              do: opts |> grep(pattern, relative) |> search_result(),
              else: search_result(result)

          other ->
            search_result(other)
        end

      {:error, %Error{} = error} ->
        result("ERROR: " <> error.detail, true, [])
    end
  end

  defp rg(opts, pattern, relative) do
    argv = [
      "rg",
      "--line-number",
      "--no-heading",
      "--color",
      "never",
      "--hidden",
      "--glob",
      "!.git/**",
      "--",
      pattern,
      relative
    ]

    Command.run(opts, argv, 120_000, "tool-search-rg")
  end

  defp grep(opts, pattern, relative) do
    argv = ["grep", "-rnI", "--exclude-dir=.git", "-e", pattern, "--", relative]
    Command.run(opts, argv, 120_000, "tool-search-grep")
  end

  defp missing_rg?(output),
    do: Regex.match?(~r/(?:^|\n)(?:env: )?rg: No such file or directory(?:\n|$)/, output)

  defp search_result({:ok, command}) do
    cond do
      command.timed_out ->
        result("ERROR: Search timed out.\n" <> command.output_tail, true, [])

      command.exit_status == 1 ->
        result("No matches.", false, [])

      command.exit_status != 0 ->
        result("ERROR: Search exited #{command.exit_status}.\n" <> command.output_tail, true, [])

      true ->
        search_output(command.output_tail)
    end
  end

  defp search_result({:error, %Error{} = error}), do: result("ERROR: " <> error.detail, true, [])

  defp search_output(output) do
    output = if String.valid?(output), do: output, else: "[binary search output omitted]"
    lines = String.split(output, "\n", trim: true)
    shown = Enum.take(lines, @max_results)
    omitted = length(lines) - length(shown)
    suffix = if omitted > 0, do: "\n[#{omitted} more results omitted]", else: ""
    paths = shown |> Enum.map(&line_path/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    result(Enum.join(shown, "\n") <> suffix, false, paths)
  end

  defp line_path(line) do
    case String.split(line, ":", parts: 3) do
      [path, _line, _rest] -> path
      _invalid -> nil
    end
  end

  defp result(output, is_error, paths),
    do: %ToolResult{output: output, is_error: is_error, paths: paths}
end
