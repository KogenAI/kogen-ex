defmodule Kogen.Tooling.OutputBudget do
  @moduledoc "Budgets model-visible results using an explicit four UTF-8 bytes/token estimate."
  alias Kogen.Contracts.Redact
  alias Kogen.Resilience.RequestLog
  alias Kogen.Tooling.Context
  alias Kogen.Tooling.Paths
  alias Kogen.Tooling.ToolArgs
  alias Kogen.Tooling.ToolResult

  @default_tokens 2_000
  @notice_bytes 320

  @spec apply(Context.t(), ToolArgs.t(), String.t(), ToolResult.t()) :: ToolResult.t()
  def apply(opts, args, call_id, result) do
    full = result.output |> text() |> Redact.text()

    tokens =
      args.tool_result_tokens || Map.get(opts.project.build || %{}, :tool_result_tokens) ||
        @default_tokens

    case retain(opts, full) do
      {:ok, handle} ->
        {output, ranges, _truncated} = render(full, args, tokens, handle)

        receipt =
          receipt(
            args,
            call_id,
            byte_size(full),
            {tokens, handle, output, ranges},
            result.is_error
          )

        case RequestLog.append(opts.run_dir, receipt) do
          :ok -> %{result | output: output, receipt: receipt}
          {:error, _reason} -> error("Cannot journal tool-result budget.")
        end

      {:error, _reason} ->
        error("Cannot retain complete tool output.")
    end
  end

  defp receipt(args, call_id, bytes, {tokens, handle, output, ranges}, is_error) do
    %{
      record_kind: :tool_result,
      call_id: call_id,
      tool_name: args.name,
      tool_result_tokens: tokens,
      requested_tool_result_tokens: args.tool_result_tokens || :null,
      original_bytes: bytes,
      returned_bytes: byte_size(output),
      truncated: ranges != [[0, bytes]],
      output_offset: args.output_offset || 0,
      output_limit: args.output_limit || :null,
      ranges: ranges,
      handle: handle,
      token_estimator: "utf8-bytes/4",
      is_error: is_error
    }
  end

  @spec retrieve(Context.t(), String.t()) :: ToolResult.t()
  def retrieve(opts, handle) do
    with true <- is_binary(handle) and Regex.match?(~r/\A[a-f0-9]{64}\z/, handle),
         {:ok, path} <- Paths.log_file(opts, "tool-result-#{handle}.log"),
         true <- File.regular?(path),
         {:ok, output} <- File.read(path) do
      %ToolResult{output: output, is_error: false, paths: []}
    else
      false -> error("Unknown or unavailable tool-output handle.")
      {:error, _reason} -> error("Unknown or unavailable tool-output handle.")
    end
  end

  defp retain(opts, full) do
    handle = :sha256 |> :crypto.hash(full) |> Base.encode16(case: :lower)

    with {:ok, path} <- Paths.log_file(opts, "tool-result-#{handle}.log"),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, full) do
      {:ok, handle}
    end
  end

  defp render(full, args, tokens, handle) do
    total = byte_size(full)
    offset = min(args.output_offset || 0, total)
    count = min(args.output_limit || total, total - offset)
    {start, selected} = slice(full, offset, count)
    cap = tokens * 4
    ranged = start > 0 or byte_size(selected) < total

    if not ranged and byte_size(selected) <= cap do
      {selected, [[0, total]], false}
    else
      render_range(selected, start, total, cap, handle)
    end
  end

  defp render_range(selected, start, total, cap, handle) do
    ranges = [[start, start + byte_size(selected)]]
    range_notice = notice(total, ranges, handle)
    available = max(cap - @notice_bytes, 0)

    if byte_size(selected) + byte_size(range_notice) > cap do
      half = div(available, 2)
      {head_start, head} = slice(selected, 0, half)
      {tail_start, tail} = slice(selected, byte_size(selected) - half, half)

      ranges = [
        [start + head_start, start + head_start + byte_size(head)],
        [start + tail_start, start + tail_start + byte_size(tail)]
      ]

      notice = notice(total, ranges, handle)
      {head <> notice <> tail, ranges, true}
    else
      {selected <> range_notice, ranges, true}
    end
  end

  defp notice(total, ranges, handle),
    do:
      "\n[truncated/range: #{total} bytes; shown byte ranges #{inspect(ranges)}; " <>
        "retrieve with tool_output handle=#{handle}, output_offset and output_limit]\n"

  # Controls are byte ranges. Move boundaries inward so UTF-8 codepoints are never split.
  defp slice(text, offset, count) do
    part = binary_part(text, offset, count)
    {part, skipped} = trim_start(part, 0)
    {offset + skipped, trim_end(part)}
  end

  defp trim_start(<<byte, rest::binary>>, skipped) when byte >= 128 and byte < 192,
    do: trim_start(rest, skipped + 1)

  defp trim_start(part, skipped), do: {part, skipped}

  defp trim_end(part) do
    if String.valid?(part),
      do: part,
      else: trim_end(binary_part(part, 0, byte_size(part) - 1))
  end

  @spec text(binary()) :: String.t()
  def text(text) do
    if String.valid?(text),
      do: text,
      else: "[non-UTF-8 output, base64 encoded]\n" <> Base.encode64(text)
  end

  defp error(message), do: %ToolResult{output: "ERROR: " <> message, is_error: true, paths: []}
end
