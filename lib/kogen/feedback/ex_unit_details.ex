defmodule Kogen.Feedback.ExUnitDetails do
  @moduledoc false

  alias Kogen.Feedback.Parser.Common

  @labels ~r/^(?:code|left|right|stacktrace):/
  @headline ~r/Assertion|match \(=\) failed|^\*\* \(|Expected truthy/
  @summary ~r/^(?:Finished in|Result:|Failed:|Running ExUnit|\.+$)/
  @external_frame ~r{(?:^|/)deps/|(?:^|/)_build/|\((?:ex_unit|elixir|stdlib|kernel)\b|\bExUnit\.}
  @max_chars 599

  def message(block, test_path, workdir) do
    fields = [
      {"", error_message(block)},
      {"code: ", code(block)},
      {"left: ", field(block, "left")},
      {"right: ", field(block, "right")},
      {"project: ", project_frame(block, test_path, workdir)}
    ]

    fields = Enum.reject(fields, fn {_label, value} -> is_nil(value) or value == "" end)
    pack(fields)
  end

  def field(block, name) do
    label = name <> ":"

    case Enum.find_index(block, &String.starts_with?(String.trim(&1), label)) do
      nil ->
        nil

      index ->
        [first | rest] = Enum.drop(block, index)
        first = first |> String.trim() |> String.replace_prefix(label, "") |> String.trim()
        rest = Enum.take_while(rest, &value_line?/1)
        [first | Enum.map(rest, &String.trim/1)] |> Enum.join("\n") |> clip(400)
    end
  end

  defp value_line?(line) do
    text = String.trim(line)
    text != "" and not Regex.match?(@labels, text) and not Regex.match?(@summary, text)
  end

  defp code(block) do
    Enum.find_value(block, fn line ->
      case String.trim(line) do
        "code:" <> text -> String.trim(text)
        _other -> nil
      end
    end)
  end

  defp error_message(block) do
    start = Enum.find_index(block, &Regex.match?(@headline, String.trim(&1))) || 2

    block
    |> Enum.drop(start)
    |> Enum.take_while(&error_line?/1)
    |> Enum.take(20)
    |> Enum.map_join("\n", &String.trim/1)
    |> String.trim()
    |> case do
      "" -> "test failed"
      message -> message
    end
  end

  defp error_line?(line) do
    text = String.trim(line)
    frame? = Common.location(line) != :error and not String.starts_with?(text, "** (")
    not frame? and not Regex.match?(@labels, text) and not Regex.match?(@summary, text)
  end

  defp project_frame(block, test_path, workdir) do
    start = Enum.find_index(block, &(String.trim(&1) == "stacktrace:")) || 1

    block
    |> Enum.drop(start + 1)
    |> Enum.find_value(fn line ->
      case Common.location(line) do
        {:ok, path, number, _col, _tail} ->
          relative = Common.normalize_path(path, workdir)

          if project_path?(path, relative, test_path, workdir) and
               not Regex.match?(@external_frame, line),
             do: frame_location("#{relative}:#{number}")

        :error ->
          nil
      end
    end)
  end

  defp frame_location(value) do
    if String.length(value) > 400, do: "…" <> String.slice(value, -399, 399), else: value
  end

  defp project_path?(path, relative, test_path, workdir) do
    inside? =
      Path.type(path) == :relative or String.starts_with?(path, Path.expand(workdir) <> "/")

    inside? and relative != test_path and ".." not in Path.split(relative) and
      not String.starts_with?(relative, ["deps/", "_build/"]) and
      File.regular?(Path.join(workdir, relative))
  end

  defp pack(fields) do
    overhead =
      Enum.sum(Enum.map(fields, fn {label, _value} -> String.length(label) end)) + length(fields) -
        1

    {frames, values} = Enum.split_with(fields, fn {label, _value} -> label == "project: " end)
    frame_size = Enum.sum(Enum.map(frames, fn {_label, value} -> String.length(value) end))
    budget = max(@max_chars - overhead - frame_size, 0)
    cap = fitting_cap(values, budget, 0, @max_chars)

    Enum.map_join(fields, "\n", fn
      {"project: ", value} -> "project: " <> value
      {label, value} -> label <> clip(value, cap)
    end)
  end

  defp clip(_value, limit) when limit < 1, do: ""

  defp clip(value, limit) do
    if String.length(value) > limit, do: String.slice(value, 0, limit - 1) <> "…", else: value
  end

  defp fitting_cap(_fields, _budget, low, high) when low >= high, do: low

  defp fitting_cap(fields, budget, low, high) do
    middle = div(low + high + 1, 2)
    size = Enum.sum(Enum.map(fields, fn {_label, value} -> min(String.length(value), middle) end))

    if size <= budget,
      do: fitting_cap(fields, budget, middle, high),
      else: fitting_cap(fields, budget, low, middle - 1)
  end
end
