defmodule Kogen.Cli.Arguments do
  @moduledoc """
  Parses the command tree. Errors carry the help topic of the command that was meant, so the
  caller prints that command's help and never the whole tree.
  """

  alias Kogen.Cli.Args
  alias Kogen.Cli.Moved

  @type error :: {:usage, String.t(), [String.t()]} | {:moved, String.t()}

  @project_flags [project: :string, origin: :string, base: :string]

  @groups ~w(intent queue provider)

  # path => {command, required positionals, optional positionals, command flags, project?}
  @commands %{
    ["status"] => {:status, [], ["<slug>"], [json: :boolean, watch: :boolean], true},
    ["intent", "shape"] => {:intent_shape, ["<slug>", "<file|->"], [], [], true},
    ["intent", "approve"] => {:intent_approve, ["<slug>"], ["<hash>"], [by: :string], true},
    ["intent", "remove"] => {:intent_remove, ["<slug>"], [], [force: :boolean], true},
    ["queue", "start"] => {:queue_start, [], [], [detach: :boolean], true},
    ["queue", "stop"] => {:queue_stop, [], [], [], true},
    ["provider", "list"] => {:provider_list, [], [], [], false},
    ["provider", "login"] => {:provider_login, ["<provider>"], [], [], false},
    ["provider", "logout"] => {:provider_logout, ["<provider>"], [], [], false},
    ["provider", "use"] =>
      {:provider_use, ["<provider>"], [], [as: :string, project: :string], false},
    ["version"] => {:version, [], [], [], false}
  }

  @spec parse([String.t()]) :: {:ok, Args.t()} | {:error, error()}
  def parse(argv) do
    case Moved.message(argv) do
      nil -> parse_tree(argv)
      message -> {:error, {:moved, message}}
    end
  end

  defp parse_tree([]), do: help([])
  defp parse_tree(["help"]), do: help([])

  defp parse_tree(["help", extra | _rest]),
    do: usage([], "kogen help: unexpected argument '#{extra}'")

  defp parse_tree([group | rest]) when group in @groups do
    case rest do
      [] -> help([group])
      [sub | rest] -> parse_subcommand(group, sub, rest)
    end
  end

  defp parse_tree([name | rest]) when is_map_key(@commands, [name]), do: command([name], rest)

  defp parse_tree([name | _rest]), do: usage([], "kogen: unknown command '#{name}'")

  defp parse_subcommand(group, sub, rest) do
    if is_map_key(@commands, [group, sub]),
      do: command([group, sub], rest),
      else: usage([group], "kogen #{group}: unknown command '#{sub}'")
  end

  defp command(path, argv) do
    {name, required, optional, flags, project?} = Map.fetch!(@commands, path)
    switches = if project?, do: flags ++ @project_flags, else: flags

    {options, positionals, invalid} = OptionParser.parse(argv, strict: switches)

    with :ok <- no_invalid_options(path, invalid, switches),
         :ok <- positional_count(path, positionals, required, optional),
         :ok <- valid_values(path, name, positionals, options) do
      {:ok, args(name, positionals, options)}
    end
  end

  defp args(name, positionals, options) do
    %Args{
      command: name,
      positionals: positionals,
      project: Keyword.get(options, :project),
      origin: Keyword.get(options, :origin),
      base: Keyword.get(options, :base),
      by: Keyword.get(options, :by),
      account_label: Keyword.get(options, :as),
      force: Keyword.get(options, :force, false),
      json: Keyword.get(options, :json, false),
      watch: Keyword.get(options, :watch, false),
      detach: Keyword.get(options, :detach, false)
    }
  end

  defp no_invalid_options(_path, [], _switches), do: :ok

  defp no_invalid_options(path, [{option, _value} | _rest], switches) do
    known? = Enum.any?(switches, fn {name, _type} -> option == "--#{name}" end)

    if known?,
      do: usage(path, "#{prefix(path)}: #{option} needs a value"),
      else: usage(path, "#{prefix(path)}: unknown option '#{option}'")
  end

  defp positional_count(path, positionals, required, optional) do
    count = length(positionals)

    cond do
      count < length(required) ->
        usage(path, "#{prefix(path)}: missing #{Enum.at(required, count)}")

      count > length(required) + length(optional) ->
        extra = Enum.at(positionals, length(required) + length(optional))
        usage(path, "#{prefix(path)}: unexpected argument '#{extra}'")

      true ->
        :ok
    end
  end

  defp valid_values(path, name, [provider | _rest], _options)
       when name in [:provider_login, :provider_logout, :provider_use] and provider != "chatgpt",
       do: usage(path, "#{prefix(path)}: unknown provider '#{provider}' (supported: chatgpt)")

  defp valid_values(path, :intent_approve, [_slug, hash], _options) do
    if Regex.match?(~r/\A[0-9a-f]{6,64}\z/, hash),
      do: :ok,
      else: usage(path, "#{prefix(path)}: <hash> must be 6 to 64 lowercase hex characters")
  end

  defp valid_values(path, :status, _positionals, options) do
    if Keyword.get(options, :watch, false) and Keyword.get(options, :json, false),
      do: usage(path, "#{prefix(path)}: --watch and --json can't be combined"),
      else: :ok
  end

  defp valid_values(path, :provider_use, _positionals, options) do
    if Keyword.get(options, :as) in [nil, ""],
      do: usage(path, "#{prefix(path)}: missing --as <label>"),
      else: :ok
  end

  defp valid_values(_path, _name, _positionals, _options), do: :ok

  defp prefix(path), do: Enum.join(["kogen" | path], " ")

  defp help(topic), do: {:ok, %Args{command: :help, positionals: topic}}

  defp usage(topic, message), do: {:error, {:usage, message, topic}}
end
