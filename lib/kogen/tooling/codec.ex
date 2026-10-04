defmodule Kogen.Tooling.Codec do
  @moduledoc "Validates Builder tool calls and publishes their provider schemas."

  alias Kogen.Contracts.ToolCall
  alias Kogen.Tooling.ToolArgs

  @tool_order [:read, :search, :edit, :write, :shell]

  @type tool_name :: :read | :search | :edit | :write | :shell
  @type builder_tool_set :: :full | :shell

  @spec tool_names(:developer | :context | :shaper) :: [tool_name()]
  def tool_names(:developer), do: tool_names(:developer, :full)
  def tool_names(:context), do: [:read, :search]
  def tool_names(:shaper), do: [:read, :search, :write]

  @spec tool_names(:developer, builder_tool_set()) :: [tool_name()]
  def tool_names(:developer, :full), do: @tool_order
  def tool_names(:developer, :shell), do: [:shell]

  @spec decode_tool_call(ToolCall.t()) :: {:ok, ToolArgs.t()} | {:error, :invalid_arguments}
  def decode_tool_call(%ToolCall{name: name, arguments: arguments}) when is_map(arguments) do
    with {:ok, tool} <- tool_name(name) do
      decode_arguments(tool, arguments)
    end
  end

  def decode_tool_call(_call), do: {:error, :invalid_arguments}

  @spec tool_specs([tool_name()]) :: [map()]
  def tool_specs(tool_names) do
    tool_names
    |> Enum.uniq()
    |> Enum.filter(&(&1 in @tool_order))
    |> Enum.map(&tool_spec/1)
  end

  defp tool_spec(:read) do
    function_tool(
      "read",
      "Read numbered lines from a file in the worktree.",
      %{
        "path" => string_schema("Relative or worktree-local absolute path."),
        "offset" => integer_schema("One-based first line; defaults to 1."),
        "limit" => integer_schema("Line count from 1 to 400; defaults to 200.")
      },
      ["path"]
    )
  end

  defp tool_spec(:search) do
    function_tool(
      "search",
      "Search file contents with rg or grep inside the worktree.",
      %{
        "pattern" => string_schema("Literal or regular expression to search for."),
        "path" =>
          string_schema("Optional worktree-local file or directory; defaults to the root.")
      },
      ["pattern"]
    )
  end

  defp tool_spec(:edit) do
    function_tool(
      "edit",
      "Replace one exact, unique text block in a file.",
      %{
        "path" => string_schema("Relative or worktree-local absolute path."),
        "old_text" => string_schema("Text that must match exactly once."),
        "new_text" => string_schema("Replacement text.")
      },
      ["path", "old_text", "new_text"]
    )
  end

  defp tool_spec(:write) do
    function_tool(
      "write",
      "Create or replace a file with at most 200 existing lines.",
      %{
        "path" => string_schema("Relative or worktree-local absolute path."),
        "content" => string_schema("Complete UTF-8 file contents.")
      },
      ["path", "content"]
    )
  end

  defp tool_spec(:shell) do
    function_tool(
      "shell",
      "Run a command through non-login sh in the worktree, with a 120 second deadline.",
      %{"cmd" => string_schema("Shell command to run from the worktree root.")},
      ["cmd"]
    )
  end

  defp function_tool(name, description, properties, required) do
    %{
      "type" => "function",
      "name" => name,
      "description" => description,
      "parameters" => %{
        "type" => "object",
        "properties" => properties,
        "required" => required,
        "additionalProperties" => false
      },
      "strict" => false
    }
  end

  defp string_schema(description), do: %{"type" => "string", "description" => description}
  defp integer_schema(description), do: %{"type" => "integer", "description" => description}

  defp tool_name("read"), do: {:ok, "read"}
  defp tool_name("search"), do: {:ok, "search"}
  defp tool_name("edit"), do: {:ok, "edit"}
  defp tool_name("write"), do: {:ok, "write"}
  defp tool_name("shell"), do: {:ok, "shell"}
  defp tool_name(_unknown), do: {:error, :invalid_arguments}

  defp decode_arguments("read", arguments) do
    with {:ok, path} <- required_string(arguments, "path"),
         {:ok, offset} <- optional_integer(arguments, "offset"),
         {:ok, limit} <- optional_integer(arguments, "limit") do
      {:ok, %ToolArgs{name: "read", path: path, offset: offset, limit: limit}}
    end
  end

  defp decode_arguments("search", arguments) do
    with {:ok, pattern} <- required_string(arguments, "pattern"),
         {:ok, path} <- optional_string(arguments, "path") do
      {:ok, %ToolArgs{name: "search", pattern: pattern, path: path}}
    end
  end

  defp decode_arguments("edit", arguments) do
    with {:ok, path} <- required_string(arguments, "path"),
         {:ok, old_text} <- required_string(arguments, "old_text"),
         {:ok, new_text} <- required_string(arguments, "new_text") do
      {:ok, %ToolArgs{name: "edit", path: path, old_text: old_text, new_text: new_text}}
    end
  end

  defp decode_arguments("write", arguments) do
    with {:ok, path} <- required_string(arguments, "path"),
         {:ok, content} <- required_string(arguments, "content") do
      {:ok, %ToolArgs{name: "write", path: path, content: content}}
    end
  end

  defp decode_arguments("shell", arguments) do
    with {:ok, cmd} <- required_string(arguments, "cmd") do
      {:ok, %ToolArgs{name: "shell", cmd: cmd}}
    end
  end

  defp required_string(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _missing -> {:error, :invalid_arguments}
    end
  end

  defp optional_string(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp optional_integer(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_integer(value) -> {:ok, value}
      _invalid -> {:error, :invalid_arguments}
    end
  end
end
