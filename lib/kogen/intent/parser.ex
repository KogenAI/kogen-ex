defmodule Kogen.Intent.Parser.SectionLines do
  @moduledoc false
  defstruct [:current, seen: [], brief: [], acceptance: [], verify: [], notes: [], request: []]
end

defmodule Kogen.Intent.Parser.Metadata do
  @moduledoc false
  defstruct title: "", size: nil, domains: []
end

defmodule Kogen.Intent.Parser.VerifyLine do
  @moduledoc false
  defstruct id: "", kind: nil, domain: nil, invalid_word: nil, line: 1
end

defmodule Kogen.Intent.Parser do
  @moduledoc false

  alias Kogen.Contracts.AcceptanceItem
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Yaml
  alias Kogen.Intent.Parser.Metadata
  alias Kogen.Intent.Parser.SectionLines
  alias Kogen.Intent.Parser.VerifyLine

  @frontmatter_keys ~w(title domains size limits blocks_on)

  @type parse_error :: %{line: pos_integer(), message: String.t()}

  @spec parse_path(Path.t()) :: {:ok, Intent.t()} | {:error, [parse_error()]}
  def parse_path(path) do
    case File.read(path) do
      {:ok, binary} -> parse_binary(binary, path)
      {:error, reason} -> error(1, "cannot read #{path}: #{inspect(reason)}")
    end
  end

  @spec parse_binary(binary(), Path.t()) :: {:ok, Intent.t()} | {:error, [parse_error()]}
  def parse_binary(binary, path) when is_binary(binary) and is_binary(path) do
    with {:ok, frontmatter, body, body_line} <- split_frontmatter(binary),
         {:ok, attrs} <- parse_metadata(frontmatter),
         {:ok, sections} <- parse_sections(body, body_line),
         {:ok, acceptance} <- parse_acceptance(sections.acceptance),
         {:ok, verifies} <- parse_verifies(sections.verify),
         :ok <- verify_ids(acceptance, verifies) do
      {:ok, build_intent(binary, path, attrs, sections, acceptance, verifies)}
    end
  end

  defp split_frontmatter(binary) do
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

  defp parse_metadata(frontmatter) do
    case Yaml.parse(frontmatter) do
      {:ok, attrs} when is_map(attrs) -> metadata(attrs, frontmatter)
      {:ok, _other} -> error(2, "frontmatter must be a YAML map")
      {:error, issues} -> offset_errors(issues, 1)
    end
  end

  defp metadata(attrs, frontmatter) do
    with :ok <- allowed_frontmatter(attrs, frontmatter),
         {:ok, title} <- required_string(attrs, "title", frontmatter),
         {:ok, size} <- required_string(attrs, "size", frontmatter),
         {:ok, domains} <- required_string_list(attrs, "domains", frontmatter),
         :ok <- optional_string_list(attrs, "limits", frontmatter),
         :ok <- optional_string_list(attrs, "blocks_on", frontmatter) do
      {:ok, %Metadata{title: title, size: size_atom(size), domains: domains}}
    end
  end

  defp allowed_frontmatter(attrs, frontmatter) do
    case Map.keys(attrs) -- @frontmatter_keys do
      [] ->
        :ok

      keys ->
        key = Enum.min(keys)
        error(attribute_line(frontmatter, key), "unknown frontmatter key #{inspect(key)}")
    end
  end

  defp required_string(attrs, key, frontmatter) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _value} ->
        error(attribute_line(frontmatter, key), "frontmatter `#{key}` must be a string")

      :error ->
        error(2, "frontmatter is missing required key `#{key}`")
    end
  end

  defp required_string_list(attrs, key, frontmatter) do
    case Map.fetch(attrs, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1),
          do: {:ok, values},
          else:
            error(
              attribute_line(frontmatter, key),
              "frontmatter `#{key}` must contain only strings"
            )

      {:ok, _value} ->
        error(attribute_line(frontmatter, key), "frontmatter `#{key}` must be a list")

      :error ->
        error(2, "frontmatter is missing required key `#{key}`")
    end
  end

  defp optional_string_list(attrs, key, frontmatter) do
    case Map.fetch(attrs, key) do
      :error ->
        :ok

      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1),
          do: :ok,
          else:
            error(
              attribute_line(frontmatter, key),
              "frontmatter `#{key}` must contain only strings"
            )

      {:ok, _value} ->
        error(attribute_line(frontmatter, key), "frontmatter `#{key}` must be a list")
    end
  end

  defp attribute_line(frontmatter, key) do
    frontmatter
    |> String.split("\n")
    |> Enum.find_index(&Regex.match?(~r/^\s*#{Regex.escape(key)}\s*:/, &1))
    |> case do
      nil -> 2
      index -> index + 2
    end
  end

  defp size_atom("small"), do: :small
  defp size_atom("medium"), do: :medium
  defp size_atom("large"), do: :large
  defp size_atom(_unknown), do: nil

  defp parse_sections(body, start_line) do
    body
    |> String.split("\n", trim: false)
    |> Enum.with_index(start_line)
    |> Enum.reduce_while({:ok, %SectionLines{current: :brief}}, &collect_section_line/2)
    |> finish_sections()
  end

  defp collect_section_line({text, line}, {:ok, sections}) do
    if sections.current == :request do
      {:cont, {:ok, append_line(sections, {line, text})}}
    else
      text = strip_cr(text)

      case section_heading(String.trim(text)) do
        nil ->
          {:cont, {:ok, append_line(sections, {line, text})}}

        {:unknown, _name} when sections.current == :brief ->
          {:cont, {:ok, append_line(sections, {line, text})}}

        {:unknown, name} ->
          {:halt, error(line, "unknown Intent section #{inspect(name)}")}

        section ->
          enter_section(sections, section, line)
      end
    end
  end

  defp enter_section(sections, section, line) do
    if section in sections.seen do
      {:halt, error(line, "duplicate #{section_name(section)} section")}
    else
      {:cont, {:ok, %{sections | current: section, seen: [section | sections.seen]}}}
    end
  end

  defp section_heading("## Acceptance"), do: :acceptance
  defp section_heading("## Verify"), do: :verify
  defp section_heading("## Notes"), do: :notes
  defp section_heading("## Request"), do: :request
  defp section_heading("## " <> name), do: {:unknown, name}
  defp section_heading(_text), do: nil

  defp section_name(:acceptance), do: "Acceptance"
  defp section_name(:verify), do: "Verify"
  defp section_name(:notes), do: "Notes"
  defp section_name(:request), do: "Request"

  defp append_line(%SectionLines{current: :brief} = sections, line),
    do: %{sections | brief: [line | sections.brief]}

  defp append_line(%SectionLines{current: :acceptance} = sections, line),
    do: %{sections | acceptance: [line | sections.acceptance]}

  defp append_line(%SectionLines{current: :verify} = sections, line),
    do: %{sections | verify: [line | sections.verify]}

  defp append_line(%SectionLines{current: :notes} = sections, line),
    do: %{sections | notes: [line | sections.notes]}

  defp append_line(%SectionLines{current: :request} = sections, line),
    do: %{sections | request: [line | sections.request]}

  defp finish_sections({:ok, sections}) do
    {:ok,
     %{
       sections
       | brief: Enum.reverse(sections.brief),
         acceptance: Enum.reverse(sections.acceptance),
         verify: Enum.reverse(sections.verify),
         notes: Enum.reverse(sections.notes),
         request: Enum.reverse(sections.request)
     }}
  end

  defp finish_sections(error), do: error

  defp parse_acceptance(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, fn {line, text}, {:ok, items} ->
      case String.trim(text) do
        "" -> {:cont, {:ok, items}}
        item_text -> parse_acceptance_line(line, item_text, items)
      end
    end)
    |> reverse_result()
  end

  defp parse_acceptance_line(line, text, items) do
    case Regex.run(~r/^-\s+A(\d+):\s*(.*)$/, text) do
      [_, number, item_text] ->
        item = %AcceptanceItem{id: "A" <> number, text: item_text, verify: nil, domain: nil}
        {:cont, {:ok, [item | items]}}

      _ ->
        {:halt, error(line, "Acceptance entries use `- A<n>: one sentence` on one line")}
    end
  end

  defp parse_verifies(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, fn {line, text}, {:ok, verifies} ->
      case String.trim(text) do
        "" -> {:cont, {:ok, verifies}}
        verify_text -> parse_verify_line(line, verify_text, verifies)
      end
    end)
    |> reverse_result()
  end

  defp parse_verify_line(line, text, verifies) do
    case Regex.run(~r/^-\s+A(\d+):\s*(.*)$/, text) do
      [_, number, body] ->
        id = "A" <> number

        if Enum.any?(verifies, &(&1.id == id)) do
          {:halt, error(line, "duplicate Verify entry for #{id}")}
        else
          {:cont, {:ok, [verify_record(id, body, line) | verifies]}}
        end

      _ ->
        {:halt, error(line, "Verify entries use `- A<n>: test` or `- A<n>: test keep`")}
    end
  end

  defp verify_record(id, body, line) do
    words = String.split(body, ~r/\s+/, trim: true)
    {kind, modifiers, invalid_kind} = verify_kind(words)
    {domain, invalid_modifier} = verify_modifiers(modifiers)

    %VerifyLine{
      id: id,
      kind: kind,
      domain: domain,
      invalid_word: invalid_kind || invalid_modifier,
      line: line
    }
  end

  defp verify_kind(["test"]), do: {:test, [], nil}
  defp verify_kind(["test", "keep" | modifiers]), do: {:test_keep, modifiers, nil}
  defp verify_kind(["test" | modifiers]), do: {:test, modifiers, nil}
  defp verify_kind(["example" | _rest]), do: {:example, [], nil}
  defp verify_kind(["check" | _rest]), do: {:check, [], nil}
  defp verify_kind([word | _rest]), do: {nil, [], word}
  defp verify_kind([]), do: {nil, [], nil}

  defp verify_modifiers(modifiers) do
    Enum.reduce_while(modifiers, {nil, nil}, fn modifier, {domain, _invalid} ->
      cond do
        modifier == "integration" ->
          {:cont, {domain, nil}}

        String.starts_with?(modifier, "domain=") and byte_size(modifier) > 7 ->
          {:cont, {String.replace_prefix(modifier, "domain=", ""), nil}}

        String.starts_with?(modifier, "after=") ->
          {:cont, {domain, nil}}

        true ->
          {:halt, {domain, modifier}}
      end
    end)
  end

  defp verify_ids(acceptance, verifies) do
    ids = MapSet.new(acceptance, & &1.id)

    case Enum.find(verifies, &(not MapSet.member?(ids, &1.id))) do
      nil -> :ok
      verify -> error(verify.line, "Verify entry #{verify.id} has no Acceptance item")
    end
  end

  defp build_intent(binary, path, metadata, sections, acceptance, verifies) do
    acceptance = Enum.map(acceptance, &attach_verify(&1, verifies))
    notes = sections.notes |> Enum.map_join("\n", &elem(&1, 1)) |> String.trim()
    brief = sections.brief |> Enum.map_join("\n", &elem(&1, 1)) |> String.trim()
    request = Enum.map_join(sections.request, "\n", &elem(&1, 1))
    parent = Path.basename(Path.dirname(path))
    slug = if parent == ".", do: Path.basename(path, Path.extname(path)), else: parent

    %Intent{
      slug: slug,
      title: metadata.title,
      size: metadata.size,
      brief: brief,
      request: if(:request in sections.seen, do: request),
      acceptance: acceptance,
      domains: metadata.domains,
      notes: if(notes == "", do: nil, else: notes),
      path: path,
      sha256: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
    }
  end

  defp attach_verify(%AcceptanceItem{} = item, verifies) do
    case Enum.find(verifies, &(&1.id == item.id)) do
      nil ->
        item

      verify ->
        %{
          item
          | verify: verify.kind,
            domain: verify.domain,
            invalid_verify: verify.invalid_word,
            verify_line: if(verify.invalid_word, do: verify.line)
        }
    end
  end

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result(error), do: error

  defp offset_errors(issues, offset) do
    {:error, Enum.map(issues, &%{&1 | line: &1.line + offset})}
  end

  defp strip_cr(text), do: String.trim_trailing(text, "\r")
  defp error(line, message), do: {:error, [%{line: line, message: message}]}
end
