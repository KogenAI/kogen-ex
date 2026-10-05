defmodule Kogen.Provider.ChatGPT.Codec.Stream do
  @moduledoc false
  defstruct buffer: "",
            event_lines: [],
            items: [],
            completed: nil,
            failure: nil,
            malformed?: false

  @type t :: %__MODULE__{
          buffer: binary(),
          event_lines: [binary()],
          items: [map()],
          completed: map() | nil,
          failure: Kogen.Contracts.ProviderError.t() | nil,
          malformed?: boolean()
        }
end

defmodule Kogen.Provider.ChatGPT.SSE do
  @moduledoc false

  alias Kogen.Provider.ChatGPT.Codec.Stream

  def new_stream, do: %Stream{}

  def feed(%Stream{} = stream, chunk, decode_event) do
    combined = normalize_newlines(stream.buffer <> chunk)
    parts = :binary.split(combined, "\n\n", [:global])
    {frames, [buffer]} = Enum.split(parts, length(parts) - 1)
    Enum.reduce(frames, %{stream | buffer: buffer}, &read_frame(&1, &2, decode_event))
  end

  def flush(%Stream{buffer: ""} = stream, _decode_event), do: stream

  def flush(%Stream{buffer: buffer} = stream, decode_event) do
    frame = <<buffer::binary, "\n\n">>
    read_frame(frame, %{stream | buffer: ""}, decode_event)
  end

  @doc "True when every line of `chunk` is a comment, a blank, or part of a keepalive event."
  def keepalive?(chunk) do
    chunk
    |> normalize_newlines()
    |> :binary.split("\n", [:global])
    |> Enum.all?(&keepalive_line?/1)
  end

  def data(frame) do
    frame
    |> :binary.split("\n", [:global])
    |> Enum.flat_map(fn
      <<"data:", value::binary>> -> [trim_one_space(value)]
      _line -> []
    end)
    |> Enum.join("\n")
  end

  defp read_frame(frame, stream, decode_event) do
    event = data(frame)

    if event in ["", "[DONE]"],
      do: stream,
      else: decode_event.(event, %{stream | event_lines: [event | stream.event_lines]})
  end

  defp keepalive_line?(""), do: true
  defp keepalive_line?(<<":", _comment::binary>>), do: true
  defp keepalive_line?("event: keepalive"), do: true

  defp keepalive_line?(<<"data:", value::binary>>),
    do: String.contains?(value, ~s("type":"keepalive"))

  defp keepalive_line?(_line), do: false

  defp trim_one_space(<<32, rest::binary>>), do: rest
  defp trim_one_space(value), do: value

  defp normalize_newlines(binary) do
    binary |> :binary.replace("\r\n", "\n", [:global]) |> :binary.replace("\r", "\n", [:global])
  end
end
