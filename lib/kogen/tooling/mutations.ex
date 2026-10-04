defmodule Kogen.Tooling.Mutations do
  @moduledoc false

  alias Kogen.Contracts.ToolCall
  alias Kogen.Tooling.Codec
  alias Kogen.Tooling.Context
  alias Kogen.Tooling.Error
  alias Kogen.Tooling.Paths
  alias Kogen.Tooling.ToolResult
  alias Kogen.Tooling.Tools

  @max_write_lines 200

  @spec run(Context.t(), ToolCall.t()) :: ToolResult.t()
  def run(opts, %ToolCall{name: name} = call) when name in ["edit", "write"] do
    case Codec.decode_tool_call(call) do
      {:ok, arguments} -> change(opts, arguments)
      {:error, _reason} -> result("ERROR: Tool arguments do not match the schema.", true, [])
    end
  end

  defp change(opts, %{name: "edit"} = arguments), do: edit(opts, arguments)
  defp change(opts, %{name: "write"} = arguments), do: write(opts, arguments)

  defp edit(opts, arguments) do
    with {:ok, absolute, relative} <- Paths.safe(opts, arguments.path),
         :ok <- refuse_protected(opts, relative),
         {:ok, contents} <- File.read(absolute),
         {:ok, updated} <- replace_once(contents, arguments.old_text, arguments.new_text),
         :ok <- File.write(absolute, updated) do
      mutation_result(opts, relative, "Edited #{relative}.")
    else
      {:error, %Error{} = error} -> result("ERROR: " <> error.detail, true, [])
      {:error, :enoent} -> result("ERROR: File does not exist.", true, [])
      {:error, {:match_count, count}} -> result(match_count_message(count), true, [])
      {:error, reason} -> result("ERROR: Edit failed: #{inspect(reason)}", true, [])
    end
  end

  defp replace_once(_contents, "", _new_text),
    do: {:error, %Error{reason: :empty_match, detail: "old_text must not be empty."}}

  defp replace_once(contents, old_text, new_text) do
    case :binary.matches(contents, old_text) do
      [{position, length}] ->
        before = binary_part(contents, 0, position)
        after_start = position + length
        after_text = binary_part(contents, after_start, byte_size(contents) - after_start)
        updated = before <> new_text <> after_text

        if updated == contents,
          do: {:error, %Error{reason: :unchanged, detail: "Replacement would make no change."}},
          else: {:ok, updated}

      matches ->
        {:error, {:match_count, length(matches)}}
    end
  end

  defp write(opts, arguments) do
    with {:ok, absolute, relative} <- Paths.safe(opts, arguments.path),
         :ok <- refuse_protected(opts, relative),
         :ok <- writable_size(absolute),
         :ok <- File.mkdir_p(Path.dirname(absolute)),
         :ok <- File.write(absolute, arguments.content) do
      mutation_result(opts, relative, "Wrote #{relative}.")
    else
      {:error, %Error{} = error} -> result("ERROR: " <> error.detail, true, [])
      {:error, reason} -> result("ERROR: Write failed: #{inspect(reason)}", true, [])
    end
  end

  defp refuse_protected(%Context{protected: protected}, relative) do
    if relative in protected do
      {:error,
       %Error{
         reason: :protected_path,
         detail: "#{relative} is approved and protected; change the implementation instead."
       }}
    else
      :ok
    end
  end

  defp writable_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, contents} <- File.read(path),
             true <- String.valid?(contents) do
          if line_count(contents) > @max_write_lines,
            do:
              {:error,
               %Error{
                 reason: :file_too_large,
                 detail: "Refusing to overwrite a file over 200 lines."
               }},
            else: :ok
        else
          false ->
            {:error,
             %Error{reason: :binary_file, detail: "Refusing to overwrite a non-UTF-8 file."}}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _stat} ->
        {:error, %Error{reason: :not_regular_file, detail: "Write target is not a regular file."}}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp line_count(""), do: 0

  defp line_count(contents) do
    newlines = length(:binary.matches(contents, "\n"))
    if String.ends_with?(contents, "\n"), do: newlines, else: newlines + 1
  end

  defp mutation_result(opts, relative, message) do
    diagnostics = Tools.diagnose(opts, relative)

    text =
      if diagnostics == [], do: message, else: message <> "\n" <> Enum.join(diagnostics, "\n")

    result(
      text,
      Enum.any?(diagnostics, &String.contains?(&1, ["timed out", "exited", "could not run"])),
      [relative]
    )
  end

  defp match_count_message(0), do: "old_text matched 0 times; provide exact text from the file."

  defp match_count_message(count),
    do: "old_text matched #{count} times; add context so it matches exactly once."

  defp result(output, is_error, paths),
    do: %ToolResult{output: output, is_error: is_error, paths: paths}
end
