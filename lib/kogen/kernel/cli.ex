defmodule Kogen.Kernel.CLI do
  @moduledoc "The escript entry point for the Kogen command line."
  use Boundary,
    deps: [Kogen.Cli, Kogen.Contracts, Kogen.Engine, Kogen.Kernel, Kogen.Queue],
    exports: []

  alias Kogen.Cli.Args
  alias Kogen.Cli.Arguments
  alias Kogen.Cli.Help
  alias Kogen.Kernel.CLI.Runner

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    main(argv, &execute/1)
  end

  @doc false
  @spec main([String.t()], ([String.t()] -> {non_neg_integer(), String.t()})) :: no_return()
  def main(argv, executor) do
    preload_modules()
    {status, output} = Kogen.Kernel.CLI.Signal.run(argv, executor)
    IO.write(output)
    System.halt(status)
  end

  # An escript loads modules lazily from its archive. Loading everything up front
  # keeps atoms and code consistent for the whole run, even if the installed file changes.
  defp preload_modules do
    _ = Application.load(:kogen)
    {:ok, modules} = :application.get_key(:kogen, :modules)
    Enum.each(modules, &Code.ensure_loaded!/1)
  end

  @spec execute([String.t()]) :: {non_neg_integer(), String.t()}
  def execute(argv) do
    case Arguments.parse(argv) do
      {:ok, %Args{command: :help, positionals: topic}} -> {0, Help.render(topic)}
      {:ok, %Args{} = args} -> Runner.run(normalize_paths(args))
      {:error, {:usage, message, topic}} -> {2, message <> "\n\n" <> Help.render(topic)}
      {:error, {:moved, message}} -> {2, "kogen: moved: use #{message}\n"}
    end
  end

  @machine_commands [:version, :provider_list, :provider_login, :provider_logout, :provider_use]

  defp normalize_paths(%Args{} = args) do
    project =
      case args.project do
        nil when args.command in @machine_commands -> nil
        nil -> File.cwd!()
        path -> Path.expand(path)
      end

    %{args | project: project, origin: expand_optional_path(args.origin)}
  end

  defp expand_optional_path(nil), do: nil
  defp expand_optional_path(path), do: Path.expand(path)
end
