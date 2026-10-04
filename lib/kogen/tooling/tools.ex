defmodule Kogen.Tooling.Tools do
  @moduledoc false

  alias Kogen.Contracts.ToolCall
  alias Kogen.Tooling.Codec
  alias Kogen.Tooling.Command
  alias Kogen.Tooling.Context
  alias Kogen.Tooling.Error
  alias Kogen.Tooling.Mutations
  alias Kogen.Tooling.ReadSearch
  alias Kogen.Tooling.ToolResult

  @tool_deadline_ms 120_000

  @spec run(Context.t(), ToolCall.t(), [Codec.tool_name()]) :: ToolResult.t()
  def run(%Context{} = opts, %ToolCall{} = call, allowed_tools) do
    if tool_atom(call.name) in allowed_tools do
      call |> dispatch(opts) |> cap_result()
    else
      tool_error(:tool_not_allowed, "This stage does not allow the requested tool.")
    end
  end

  @spec run_read_only(Context.t(), ToolCall.t()) :: ToolResult.t()
  def run_read_only(opts, %ToolCall{} = call), do: run(opts, call, [:read, :search])

  defp dispatch(%ToolCall{name: "read"} = call, opts), do: ReadSearch.run(opts, call)
  defp dispatch(%ToolCall{name: "search"} = call, opts), do: ReadSearch.run(opts, call)
  defp dispatch(%ToolCall{name: "edit"} = call, opts), do: Mutations.run(opts, call)
  defp dispatch(%ToolCall{name: "write"} = call, opts), do: Mutations.run(opts, call)

  defp dispatch(%ToolCall{name: "shell"} = call, opts), do: run_shell(opts, call)

  defp dispatch(_call, _opts), do: tool_error(:unknown_tool, "Unknown tool name.")

  defp cap_result(%ToolResult{} = result), do: %{result | output: clip_tail(result.output)}

  defp run_shell(opts, %ToolCall{} = call) do
    case Codec.decode_tool_call(call) do
      {:ok, %{cmd: cmd}} -> shell_command(opts, cmd)
      {:error, _reason} -> tool_error(:invalid_arguments, "shell requires a string cmd.")
    end
  end

  defp shell_command(opts, cmd) do
    case Command.run(opts, ["sh", "-c", cmd], @tool_deadline_ms, "tool-shell") do
      {:ok, result} -> shell_result(result)
      {:error, %Error{} = error} -> tool_error(error.reason, error.detail)
    end
  end

  defp shell_result(result) do
    output = clip_tail(result.output_tail)

    status =
      if result.timed_out, do: "timed out after 120 seconds", else: "exit #{result.exit_status}"

    tool_result("#{status}\n#{output}", result.timed_out or result.exit_status != 0, [])
  end

  @doc false
  @spec diagnose(Context.t(), Path.t()) :: [String.t()]
  def diagnose(%Context{} = opts, relative_path) do
    opts.project.diagnose
    |> Enum.filter(&matches?(&1.glob, relative_path))
    |> Enum.flat_map(&run_diagnose(opts, &1.argv, relative_path))
  end

  defp run_diagnose(opts, argv, relative_path) do
    absolute_path = Path.join(opts.workdir, relative_path)
    argv = Enum.map(argv, &diagnostic_argument(&1, relative_path, absolute_path))

    case Command.run(opts, argv, @tool_deadline_ms, "diagnose") do
      {:ok, result} -> diagnostic_output(result)
      {:error, %Error{} = error} -> ["Syntax check could not run: #{error.detail}"]
    end
  end

  defp diagnostic_argument(argument, relative_path, absolute_path) do
    argument
    |> String.replace("{files}", absolute_path)
    |> String.replace("{file}", absolute_path)
    |> String.replace("{relative_file}", relative_path)
  end

  defp diagnostic_output(result) do
    output = clip_tail(result.output_tail)

    cond do
      result.timed_out -> ["Syntax check timed out after 120 seconds.\n" <> output]
      result.exit_status != 0 -> ["Syntax check exited #{result.exit_status}.\n" <> output]
      output == "" -> []
      true -> ["Syntax check output:\n" <> output]
    end
  end

  defp matches?(glob, relative_path) do
    pattern = glob |> Regex.escape() |> String.replace("\\*\\*/", "(?:.*/)?")
    pattern = pattern |> String.replace("\\*", "[^/]*") |> String.replace("\\?", "[^/]")
    Regex.match?(Regex.compile!("^" <> pattern <> "$"), relative_path)
  end

  defp tool_atom("read"), do: :read
  defp tool_atom("search"), do: :search
  defp tool_atom("edit"), do: :edit
  defp tool_atom("write"), do: :write
  defp tool_atom("shell"), do: :shell
  defp tool_atom(_unknown), do: nil

  defp clip_tail(text) when is_binary(text) do
    if String.valid?(text) do
      if String.length(text) > 10_000,
        do: String.slice(text, String.length(text) - 10_000, 10_000),
        else: text
    else
      tail = binary_part(text, max(byte_size(text) - 7_400, 0), min(byte_size(text), 7_400))
      "[non-UTF-8 output tail, base64 encoded]\n" <> Base.encode64(tail)
    end
  end

  defp clip_tail(text), do: inspect(text)

  defp tool_result(output, is_error, paths),
    do: %ToolResult{output: output, is_error: is_error, paths: paths}

  defp tool_error(reason, detail), do: tool_result("ERROR (#{reason}): " <> detail, true, [])
end
