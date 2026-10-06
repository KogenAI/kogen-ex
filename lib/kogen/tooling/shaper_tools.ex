defmodule Kogen.Tooling.ShaperTools do
  @moduledoc false

  alias Kogen.Contracts.ToolCall
  alias Kogen.Tooling.Codec
  alias Kogen.Tooling.Context
  alias Kogen.Tooling.Error
  alias Kogen.Tooling.OutputBudget
  alias Kogen.Tooling.Paths
  alias Kogen.Tooling.ToolArgs
  alias Kogen.Tooling.ToolResult
  alias Kogen.Tooling.Tools

  @max_write_bytes 200_000

  @spec run(Context.t(), ToolCall.t(), [String.t()]) :: ToolResult.t()
  def run(%Context{} = opts, %ToolCall{name: name} = call, allowed_paths) do
    case name do
      "read" ->
        Tools.run_read_only(opts, call)

      "search" ->
        Tools.run_read_only(opts, call)

      "tool_output" ->
        Tools.run_read_only(opts, call)

      "write" ->
        write(opts, call, allowed_paths)

      _other ->
        tool_error(
          :tool_not_allowed,
          "The shaper only allows read, search, write, and tool_output."
        )
    end
  end

  defp write(opts, %ToolCall{} = call, allowed_paths) do
    case Codec.decode_tool_call(call) do
      {:ok, %{name: "write"} = args} ->
        result = requested_write(opts, args.path, args.content, allowed_paths)
        OutputBudget.apply(opts, args, call.id, result)

      {:error, :invalid_arguments} ->
        error = result("ERROR: Tool arguments do not match the write schema.", true, [])
        OutputBudget.apply(opts, %ToolArgs{name: "write"}, call.id, error)
    end
  end

  defp requested_write(opts, requested, content, allowed_paths) do
    case Paths.safe(opts, requested) do
      {:ok, absolute, relative} ->
        perform_write(absolute, relative, content, allowed_paths)

      {:error, %Error{} = error} ->
        result("ERROR: " <> error.detail, true, [])
    end
  end

  defp perform_write(absolute, relative, content, allowed_paths) do
    with :ok <- allowed_path(relative, allowed_paths),
         :ok <- writable_target(absolute, content),
         :ok <- File.mkdir_p(Path.dirname(absolute)),
         :ok <- File.write(absolute, content, [:binary]) do
      result("Wrote #{relative}.", false, [relative])
    else
      {:error, %Error{} = error} -> result("ERROR: " <> error.detail, true, [])
      {:error, reason} -> result("ERROR: Write failed: #{inspect(reason)}", true, [])
    end
  end

  defp allowed_path(path, allowed_paths) do
    if path in allowed_paths,
      do: :ok,
      else:
        {:error,
         %Error{
           reason: :write_scope,
           detail:
             "Write target is outside the shaper's two-file scope. Allowed paths: " <>
               Enum.join(allowed_paths, ", ") <> "."
         }}
  end

  defp writable_target(path, content) do
    if byte_size(content) > @max_write_bytes do
      {:error, %Error{reason: :file_too_large, detail: "Refusing to write more than 200 KB."}}
    else
      regular_target(path)
    end
  end

  defp regular_target(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, _stat} ->
        {:error, %Error{reason: :not_regular_file, detail: "Write target is not a regular file."}}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tool_error(reason, detail), do: result("ERROR (#{reason}): " <> detail, true, [])

  defp result(output, is_error, paths),
    do: %ToolResult{output: output, is_error: is_error, paths: paths}
end
