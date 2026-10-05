defmodule Kogen.Kernel.CLI.Arguments do
  @moduledoc false

  alias Kogen.Kernel.CLI.Args

  @switches [
    project: :string,
    origin: :string,
    base: :string,
    by: :string,
    task_file: :string,
    as: :string,
    yes: :boolean,
    json: :boolean
  ]

  @spec parse([String.t()]) :: {:ok, Args.t()} | {:error, String.t()}
  def parse([]), do: {:ok, %Args{command: :help}}
  def parse(["--help"]), do: {:ok, %Args{command: :help}}
  def parse(["help"]), do: {:ok, %Args{command: :help}}
  def parse(["help", command]), do: help_args([command])
  def parse(["help", command, subcommand]), do: help_args([command, subcommand])
  def parse(["--version" | rest]), do: parse_options(:version, [], rest)
  def parse(["version", "--help"]), do: help_args(["version"])
  def parse(["version" | rest]), do: parse_options(:version, [], rest)
  def parse(["intent"]), do: help_args(["intent"])
  def parse(["intent", "--help"]), do: help_args(["intent"])
  def parse(["intent", "check", "--help"]), do: help_args(["intent", "check"])
  def parse(["intent", "shape", "--help"]), do: help_args(["intent", "shape"])
  def parse(["intent", "approve", "--help"]), do: help_args(["intent", "approve"])
  def parse(["intent", "check", path | rest]), do: parse_options(:intent_check, [path], rest)
  def parse(["intent", "shape", slug | rest]), do: parse_options(:intent_shape, [slug], rest)
  def parse(["intent", "approve", slug | rest]), do: parse_options(:intent_approve, [slug], rest)
  def parse(["approve" | _rest]), do: {:error, "moved: use kogen intent approve <slug>"}
  def parse(["build"]), do: help_args(["build"])
  def parse(["build", "--help"]), do: help_args(["build"])
  def parse(["build", "show", "--help"]), do: help_args(["build", "show"])
  def parse(["build", "show", slug | rest]), do: parse_options(:build_show, [slug], rest)
  def parse(["build", slug | rest]), do: parse_options(:build, [slug], rest)
  def parse(["report" | _rest]), do: {:error, "moved: use kogen build show <slug>"}
  def parse(["provider"]), do: help_args(["provider"])
  def parse(["provider", "--help"]), do: help_args(["provider"])
  def parse(["provider", "list", "--help"]), do: help_args(["provider", "list"])
  def parse(["provider", "login", "--help"]), do: help_args(["provider", "login"])
  def parse(["provider", "logout", "--help"]), do: help_args(["provider", "logout"])
  def parse(["provider", "list" | rest]), do: parse_options(:provider_list, [], rest)

  def parse(["provider", "login", provider | rest]),
    do: parse_options(:provider_login, [provider], rest)

  def parse(["provider", "logout", provider | rest]),
    do: parse_options(:provider_logout, [provider], rest)

  def parse(["status", "--help"]), do: help_args(["status"])
  def parse(["status" | rest]), do: parse_options(:status, [], rest)
  def parse(["reconcile", "--help"]), do: help_args(["reconcile"])
  def parse(["reconcile", run_id | rest]), do: parse_options(:reconcile, [run_id], rest)

  def parse(argv) do
    case moved_option(:unknown, argv) do
      nil -> {:error, "invalid command or arguments"}
      message -> {:error, message}
    end
  end

  defp help_args(topic), do: {:ok, %Args{command: :help, positionals: topic}}

  defp parse_options(command, positionals, argv) do
    case moved_option(command, argv) do
      nil -> do_parse_options(command, positionals, argv)
      message -> {:error, message}
    end
  end

  defp do_parse_options(command, positionals, argv) do
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
         by: Keyword.get(options, :by),
         task_file: Keyword.get(options, :task_file),
         account_label: Keyword.get(options, :as),
         yes: Keyword.get(options, :yes, false),
         json: Keyword.get(options, :json, false)
       }}
    end
  end

  defp no_unknown_options([], []), do: :ok
  defp no_unknown_options(_leftovers, _invalid), do: {:error, "unknown option or argument"}

  defp valid_positionals(command, []) when command in [:status, :provider_list, :version], do: :ok
  defp valid_positionals(_command, [_one]), do: :ok
  defp valid_positionals(_command, _positionals), do: {:error, "invalid number of arguments"}

  defp valid_provider_target(command, ["chatgpt"])
       when command in [:provider_login, :provider_logout], do: :ok

  defp valid_provider_target(command, _positionals)
       when command in [:provider_login, :provider_logout],
       do: {:error, "only the chatgpt provider is supported"}

  defp valid_provider_target(_command, _positionals), do: :ok

  defp valid_flags(command, options) do
    case Keyword.keys(options) -- allowed_flags(command) do
      [] -> required_flags(command, options)
      _unknown -> {:error, "option is not valid for this command"}
    end
  end

  defp allowed_flags(:intent_check), do: project_flags()

  defp allowed_flags(:intent_shape), do: project_flags() ++ [:task_file, :json]

  defp allowed_flags(:intent_approve), do: project_flags() ++ [:by, :yes]
  defp allowed_flags(:version), do: []
  defp allowed_flags(:build), do: project_flags()
  defp allowed_flags(:build_show), do: project_flags() ++ [:json]
  defp allowed_flags(:provider_list), do: []
  defp allowed_flags(:provider_login), do: [:as]
  defp allowed_flags(:provider_logout), do: [:as]
  defp allowed_flags(:status), do: project_flags() ++ [:json]
  defp allowed_flags(:reconcile), do: project_flags()

  defp project_flags, do: [:project, :origin, :base]

  defp required_flags(:intent_approve, options) do
    if Keyword.has_key?(options, :by), do: :ok, else: {:error, "intent approve requires --by"}
  end

  defp required_flags(:intent_shape, options) do
    case Keyword.get(options, :task_file) do
      path when is_binary(path) and path != "" -> :ok
      _missing -> {:error, "intent shape requires --task-file"}
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
    origin = options |> Keyword.get(:origin) |> expand_optional_path()
    base = Keyword.get(options, :base)
    {:ok, project, origin, base}
  end

  defp expand_optional_path(nil), do: nil
  defp expand_optional_path(path), do: Path.expand(path)

  defp moved_option(command, argv) do
    case moved_borrow(argv) do
      nil ->
        case moved_build_setting(argv) do
          nil -> moved_account(command, argv)
          message -> message
        end

      message ->
        message
    end
  end

  defp moved_borrow(argv) do
    if option?(argv, "--borrow"),
      do: "moved: use kogen provider login chatgpt for a Kogen-owned login"
  end

  defp moved_build_setting(argv) do
    cond do
      option?(argv, "--recipe") -> "moved: set build.recipe in .kogen/project.yaml"
      option?(argv, "--model") -> "moved: set build.roles.builder.model in .kogen/project.yaml"
      option?(argv, "--effort") -> "moved: set build.roles.builder.effort in .kogen/project.yaml"
      true -> nil
    end
  end

  defp moved_account(command, argv) do
    if command not in [:provider_login, :provider_logout, :provider_list] and
         option?(argv, "--as"),
       do: "moved: set account in .kogen/project.yaml"
  end

  defp option?(argv, name),
    do: Enum.any?(argv, &(&1 == name or String.starts_with?(&1, name <> "=")))
end
