defmodule Kogen.Harness.Codec do
  @moduledoc "Converts model wire maps and transcript values to typed Harness data."

  alias Kogen.Contracts.JSON
  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness.TranscriptEntry
  alias Kogen.Harness.Usage
  alias Kogen.Tooling.Codec, as: ToolingCodec
  alias Kogen.Tooling.ToolArgs

  @type tool_name :: ToolingCodec.tool_name()
  @type builder_tool_set :: ToolingCodec.builder_tool_set()

  @spec request(String.t(), String.t(), String.t(), [map()], [tool_name()]) :: ModelRequest.t()
  def request(model, effort, instructions, input, tool_names) do
    %ModelRequest{
      model: model,
      effort: effort,
      instructions: instructions,
      input: input,
      tools: ToolingCodec.tool_specs(tool_names),
      previous_response_id: nil
    }
  end

  @spec user_item(String.t()) :: map()
  def user_item(text),
    do: %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}

  @doc "Encrypted reasoning items belong to the model that produced them, so a fallback model drops them."
  @spec without_reasoning([map()]) :: [map()]
  def without_reasoning(items), do: Enum.reject(items, &(Map.get(&1, "type") == "reasoning"))

  @spec function_output(String.t(), String.t()) :: map()
  def function_output(call_id, output),
    do: %{"type" => "function_call_output", "call_id" => call_id, "output" => output}

  @spec tool_names(:developer | :context | :shaper) :: [tool_name()]
  def tool_names(stage), do: ToolingCodec.tool_names(stage)

  @spec tool_names(:developer, builder_tool_set()) :: [tool_name()]
  def tool_names(:developer, tool_set), do: ToolingCodec.tool_names(:developer, tool_set)

  @spec decode_tool_call(ToolCall.t()) :: {:ok, ToolArgs.t()} | {:error, :invalid_arguments}
  def decode_tool_call(call), do: ToolingCodec.decode_tool_call(call)

  @spec parse_review(String.t()) :: {:ok, {:accept | :revise, [String.t()]}} | :error
  def parse_review(text) when is_binary(text) do
    with {:ok, %{} = object} <- decode_json(text),
         {:ok, verdict} <- review_verdict(object),
         {:ok, findings} <- review_findings(object) do
      {:ok, {verdict, findings}}
    else
      _invalid -> :error
    end
  end

  def parse_review(_text), do: :error

  @audit_verdicts %{
    "valid" => :valid,
    "over_strict" => :over_strict,
    "contradicts" => :contradicts
  }

  @doc "Auditor verdicts from a JSON reply, tolerating a surrounding code fence; [] if invalid."
  @spec parse_audit(String.t()) :: [%{id: String.t(), verdict: atom(), reason: String.t()}]
  def parse_audit(text) when is_binary(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> json |> decode_json() |> audit_items()
      nil -> []
    end
  end

  defp audit_items({:ok, %{"items" => items}}) when is_list(items),
    do: Enum.flat_map(items, &audit_item/1)

  defp audit_items(_invalid), do: []

  defp audit_item(%{"id" => id, "verdict" => verdict} = item) when is_binary(id) do
    case Map.fetch(@audit_verdicts, verdict) do
      {:ok, value} ->
        reason = Map.get(item, "reason")
        [%{id: id, verdict: value, reason: if(is_binary(reason), do: reason, else: "")}]

      :error ->
        []
    end
  end

  defp audit_item(_item), do: []

  @spec usage(Usage.t(), map()) :: Usage.t()
  def usage(%Usage{} = total, response_usage) when is_map(response_usage) do
    Usage.add(total, provider_usage(response_usage))
  end

  @spec encode_entry(TranscriptEntry.t()) :: {:ok, binary()} | {:error, :invalid_transcript_value}
  def encode_entry(%TranscriptEntry{} = entry) do
    entry
    |> wire_value()
    |> encode_json()
  end

  @spec encode_json_value(term()) :: {:ok, binary()} | {:error, :invalid_transcript_value}
  def encode_json_value(value), do: value |> wire_value() |> encode_json()

  defp review_verdict(object) do
    case Map.fetch(object, "verdict") do
      {:ok, "accept"} -> {:ok, :accept}
      {:ok, "revise"} -> {:ok, :revise}
      _invalid -> :error
    end
  end

  defp review_findings(object) do
    case Map.fetch(object, "findings") do
      {:ok, findings} when is_list(findings) ->
        if Enum.all?(findings, &is_binary/1), do: {:ok, findings}, else: :error

      _invalid ->
        :error
    end
  end

  defp provider_usage(usage) do
    %Usage{
      input: Map.get(usage, :input, 0),
      cached_input: Map.get(usage, :cached_input, 0),
      cache_write: Map.get(usage, :cache_write, 0),
      output: Map.get(usage, :output, 0),
      reasoning: Map.get(usage, :reasoning, 0)
    }
  end

  defp decode_json(text), do: JSON.decode(text)

  defp encode_json(value) do
    {:ok, value |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    ErlangError -> {:error, :invalid_transcript_value}
  end

  defp wire_value(%_{} = struct), do: struct |> Map.from_struct() |> wire_value()
  defp wire_value(value) when is_map(value), do: Map.new(value, &wire_pair/1)
  defp wire_value(value) when is_list(value), do: Enum.map(value, &wire_value/1)
  defp wire_value(value) when is_binary(value), do: wire_binary(value)

  defp wire_value(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp wire_value(value), do: value

  defp wire_pair({key, value}) when is_atom(key), do: {Atom.to_string(key), wire_value(value)}
  defp wire_pair({key, value}) when is_binary(key), do: {key, wire_value(value)}
  defp wire_pair({key, value}), do: {inspect(key), wire_value(value)}

  defp wire_binary(value) do
    if String.valid?(value),
      do: value,
      else: %{"encoding" => "base64", "data" => Base.encode64(value)}
  end
end
