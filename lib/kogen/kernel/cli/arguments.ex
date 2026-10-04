defmodule Kogen.Kernel.CLI.Arguments do
  @moduledoc false

  alias Kogen.Kernel.CLI.Args

  @switches [
    project: :string,
    origin: :string,
    base: :string,
    model: :string,
    effort: :string,
    recipe: :string,
    by: :string,
    task_file: :string,
    as: :string,
    borrow: :string,
    yes: :boolean,
    json: :boolean
  ]

  @spec parse([String.t()]) :: {:ok, Args.t()} | {:error, String.t()}
  def parse(["--help"]), do: {:ok, %Args{command: :help}}
  def parse(["help"]), do: {:ok, %Args{command: :help}}
  def parse(["version" | rest]), do: parse_options(:version, [], rest)
  def parse(["--version" | rest]), do: parse_options(:version, [], rest)
  def parse(["intent", "check", path | rest]), do: parse_options(:intent_check, [path], rest)
  def parse(["intent", "shape", slug | rest]), do: parse_options(:intent_shape, [slug], rest)
  def parse(["approve", slug | rest]), do: parse_options(:approve, [slug], rest)
  def parse(["build", slug | rest]), do: parse_options(:build, [slug], rest)
  def parse(["provider", "list" | rest]), do: parse_options(:provider_list, [], rest)

  def parse(["provider", "login", provider | rest]),
    do: parse_options(:provider_login, [provider], rest)

  def parse(["provider", "logout", provider | rest]),
    do: parse_options(:provider_logout, [provider], rest)

  def parse(["status" | rest]), do: parse_options(:status, [], rest)
  def parse(["report", slug | rest]), do: parse_options(:report, [slug], rest)
  def parse(["reconcile", run_id | rest]), do: parse_options(:reconcile, [run_id], rest)
  def parse(_argv), do: {:error, "invalid command or arguments"}

  defp parse_options(command, positionals, argv) do
    {options, leftovers, invalid} = OptionParser.parse(argv, strict: @switches)

    with :ok <- no_unknown_options(leftovers, invalid),
         :ok <- valid_positionals(command, positionals),
         :ok <- valid_provider_target(command, positionals),
         :ok <- valid_flags(command, options),
         {:ok, project, origin, base} <- paths(command, options) do
      {:ok,
       %Args{
         command: command,
         positionals: positionals,
         project: project,
         origin: origin,
         base: base,
         model: Keyword.get(options, :model, "gpt-6-luna"),
         effort: Keyword.get(options, :effort, "max"),
         recipe: Keyword.get(options, :recipe, "staged"),
         by: Keyword.get(options, :by),
         task_file: Keyword.get(options, :task_file),
         account_label: Keyword.get(options, :as),
         borrow: Keyword.get(options, :borrow),
         yes: Keyword.get(options, :yes, false),
         json: Keyword.get(options, :json, false)
       }}
    end
  end

  defp no_unknown_options([], []), do: :ok
  defp no_unknown_options(_leftovers, _invalid), do: {:error, "unknown option or argument"}

  defp valid_positionals(:status, []), do: :ok
  defp valid_positionals(:provider_list, []), do: :ok
  defp valid_positionals(:version, []), do: :ok
  defp valid_positionals(_command, [_one]), do: :ok
  defp valid_positionals(_command, _positionals), do: {:error, "invalid number of arguments"}

  defp valid_provider_target(command, ["chatgpt"])
       when command in [:provider_login, :provider_logout], do: :ok

  defp valid_provider_target(command, _positionals)
       when command in [:provider_login, :provider_logout],
       do: {:error, "only the chatgpt provider is supported"}

  defp valid_provider_target(_command, _positionals), do: :ok

  defp valid_flags(command, options) do
    flags = Keyword.keys(options)
    allowed = allowed_flags(command)

    case flags -- allowed do
      [] -> required_flags(command, options)
      _unknown -> {:error, "option is not valid for this command"}
    end
  end

  defp allowed_flags(:intent_check), do: [:project, :origin, :base]

  defp allowed_flags(:intent_shape),
    do: [:project, :origin, :base, :model, :effort, :task_file, :json]

  defp allowed_flags(:version), do: [:project, :origin, :base]
  defp allowed_flags(:approve), do: [:project, :origin, :base, :by, :yes]

  defp allowed_flags(:build),
    do: [:project, :origin, :base, :model, :effort, :recipe, :as, :borrow]

  defp allowed_flags(:provider_list), do: []
  defp allowed_flags(:provider_login), do: [:as]
  defp allowed_flags(:provider_logout), do: [:as]
  defp allowed_flags(:status), do: [:project, :origin, :base, :json]
  defp allowed_flags(:report), do: [:project, :origin, :base, :json]
  defp allowed_flags(:reconcile), do: [:project, :origin, :base]

  defp required_flags(:approve, options) do
    if Keyword.has_key?(options, :by), do: :ok, else: {:error, "approve requires --by"}
  end

  defp required_flags(:report, options) do
    if Keyword.get(options, :json, false), do: :ok, else: {:error, "report requires --json"}
  end

  defp required_flags(:intent_shape, options) do
    case Keyword.get(options, :task_file) do
      path when is_binary(path) and path != "" -> :ok
      _missing -> {:error, "intent shape requires --task-file"}
    end
  end

  defp required_flags(:build, options) do
    borrow = Keyword.get(options, :borrow)
    recipe = Keyword.get(options, :recipe, "staged")

    cond do
      recipe not in ["staged", "direct"] ->
        {:error, "--recipe must be staged or direct"}

      borrow not in [nil, "codex"] ->
        {:error, "--borrow only supports codex"}

      borrow == "codex" and Keyword.has_key?(options, :as) ->
        {:error, "--as cannot be combined with --borrow codex"}

      true ->
        :ok
    end
  end

  defp required_flags(_command, _options), do: :ok

  defp paths(command, options) do
    case Keyword.fetch(options, :project) do
      {:ok, project} ->
        project_paths(project, options)

      :error when command in [:version, :provider_list, :provider_login, :provider_logout] ->
        {:ok, nil, nil, nil}

      :error ->
        project_paths(File.cwd!(), options)
    end
  end

  defp project_paths(project, options) do
    project = Path.expand(project)
    origin = options |> Keyword.get(:origin, project) |> Path.expand()
    base = Keyword.get(options, :base, "main")
    {:ok, project, origin, base}
  end
end
