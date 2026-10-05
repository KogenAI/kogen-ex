defmodule Kogen.Kernel.CLI do
  @moduledoc "The escript entry point for the Kogen command line."
  use Boundary, deps: [Kogen.Contracts, Kogen.Engine, Kogen.Kernel], exports: []

  alias Kogen.Kernel.CLI.Args
  alias Kogen.Kernel.CLI.Arguments
  alias Kogen.Kernel.CLI.Help
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
      {:ok, %Args{command: command} = args} -> dispatch(command, args)
      {:error, reason} -> {2, "kogen: #{reason}\n\n" <> elem(Help.render([]), 1)}
    end
  end

  defp dispatch(:help, args), do: Help.render(args.positionals)
  defp dispatch(_command, %Args{} = args), do: Runner.run(args)
end
