defmodule Kogen.Kernel.CLI do
  @moduledoc "The escript entry point for the Kogen command line."
  use Boundary, deps: [Kogen.Contracts, Kogen.Engine, Kogen.Kernel], exports: []

  alias Kogen.Kernel.CLI.Args
  alias Kogen.Kernel.CLI.Arguments
  alias Kogen.Kernel.CLI.Runner

  @usage """
  Usage: kogen <command> [arguments] [options]

  Commands:
    intent check <path>   Parse and lint an Intent
    intent shape <slug>   Create and validate an Intent (--task-file)
    approve <slug>        Review and record an Intent approval (--by, --yes)
    build <slug>          Build and land an approved Intent (--recipe staged|direct|direct-shell, --model, --effort)
    provider list         List saved ChatGPT accounts
    provider login chatgpt [--as <label>]
                          Sign in using "Continue with ChatGPT"
    provider logout chatgpt [--as <label>]
                          Sign out of a saved ChatGPT account
    status                Show Intent state (--json for JSON)
    report <slug>         Show the latest run report (--json)
    reconcile <run-id>    Reconcile a run after a crash
    version               Show the Kogen version

  Common options:
    --project <checkout>  Project checkout (default: current directory)
    --origin <repo>       Git repository used for approval and landing
    --base <branch>       Target branch (default: main)
  Intent shaping options:
    --task-file <path>    Task statement text file
    --model <name>        Provider model (default: gpt-6-luna)
    --effort <level>      Model effort (default: max)
    --recipe <name>       Build recipe (default: staged)
    --json                Emit shaping result and call usage as JSON
    --as <label>          ChatGPT account label (default: default)
    --borrow codex        Explicitly use the read-only Codex login for this Build
  """

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
      {:error, reason} -> {2, "kogen: #{reason}\n\n#{@usage}"}
    end
  end

  defp dispatch(:help, _args), do: {0, @usage}
  defp dispatch(_command, %Args{} = args), do: Runner.run(args)
end
