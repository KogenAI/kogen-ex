defmodule Kogen.Intent.Parser.Frontmatter do
  @moduledoc false

  def split(binary) do
    case String.split(binary, "\n", trim: false) do
      [opening | rest] ->
        if strip_cr(opening) == "---",
          do: split_frontmatter_body(rest),
          else: error(1, "frontmatter must start with `---`")

      [] ->
        error(1, "frontmatter must start with `---`")
    end
  end

  defp split_frontmatter_body(lines) do
    {frontmatter, closing_and_body} = Enum.split_while(lines, &(strip_cr(&1) != "---"))

    case closing_and_body do
      [_closing | body] ->
        body_line = length(frontmatter) + 3
        {:ok, Enum.join(frontmatter, "\n"), Enum.join(body, "\n"), body_line}

      [] ->
        error(length(lines) + 1, "frontmatter is missing its closing `---`")
    end
  end

  defp strip_cr(text), do: String.trim_trailing(text, "\r")
  defp error(line, message), do: {:error, [%{line: line, message: message}]}
end
