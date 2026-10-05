defmodule Kogen.Kernel.CLI.Help do
  @moduledoc false

  @top_level """
  Commands:
    status      Show project and Intent state
    intent      Check, shape, or approve an Intent
    build       Build an Intent or show a Build report
    reconcile   Reconcile a Build after a crash
    provider    Manage Kogen ChatGPT logins
    version     Show the Kogen version
    help        Show help for a command
  """

  @project_options """
  Options:
    --project <checkout>  Project checkout (default: current directory)
    --origin <repo>       Local Git repository used for state and landing
    --base <branch>       Target branch (project setting, origin HEAD, then current branch)
  """

  @spec render([String.t()]) :: {non_neg_integer(), String.t()}
  def render([]), do: {0, @top_level}

  def render(["status"]),
    do:
      {0,
       "Usage: kogen status [options]\n\n#{@project_options}    --json                Emit the status list as JSON\n"}

  def render(["intent"]) do
    {0,
     "Usage: kogen intent <command> [arguments] [options]\n\n" <>
       "Commands:\n  check <slug|path>     Parse and lint an Intent\n" <>
       "  shape <slug>          Create an Intent from --task-file\n" <>
       "  approve <slug>        Review and record an Intent approval\n\n" <>
       @project_options}
  end

  def render(["intent", "check"]) do
    {0,
     "Usage: kogen intent check <slug|path> [options]\n\n" <>
       "Checks one Intent file. A slug resolves under .kogen/intents/<slug>/intent.md.\n\n" <>
       @project_options}
  end

  def render(["intent", "shape"]) do
    {0,
     "Usage: kogen intent shape <slug> --task-file <path> [options]\n\n" <>
       "Creates and validates the Intent and its acceptance test. Model and effort come from project build settings.\n\n" <>
       @project_options <>
       "    --task-file <path>    Task statement text file\n    --json                Emit shaping usage as JSON\n"}
  end

  def render(["intent", "approve"]) do
    {0,
     "Usage: kogen intent approve <slug> --by <name> [options]\n\n" <>
       "Records an approval after review. Without --yes, approval requires a TTY.\n\n" <>
       @project_options <>
       "    --by <name>          Approval provenance\n    --yes                 Skip the TTY prompt\n"}
  end

  def render(["build"]) do
    {0,
     "Usage: kogen build <slug> [options]\n       kogen build show <slug> [options]\n\n" <>
       "Commands:\n  show <slug>           Show the latest Build report as JSON\n\n" <>
       "Build settings come from .kogen/project.yaml, with ~/.kogen/config.yaml as the machine default.\n\n" <>
       @project_options}
  end

  def render(["build", "show"]) do
    {0,
     "Usage: kogen build show <slug> [options]\n\n" <>
       "Prints the latest Build report as JSON.\n\n" <>
       @project_options <> "    --json                Accepted for explicit machine output\n"}
  end

  def render(["provider"]) do
    {0,
     "Usage: kogen provider <command> [arguments] [options]\n\n" <>
       "Commands:\n  list                  List saved ChatGPT accounts\n" <>
       "  login chatgpt         Sign in to a Kogen-owned account\n" <>
       "  logout chatgpt        Sign out of a Kogen-owned account\n"}
  end

  def render(["provider", command]) when command in ["list", "login", "logout"] do
    case command do
      "list" -> {0, "Usage: kogen provider list\n"}
      "login" -> provider_account_help("login")
      "logout" -> provider_account_help("logout")
    end
  end

  def render(["reconcile"]) do
    {0,
     "Usage: kogen reconcile <run-id> [options]\n\n" <>
       "Closes the run journal after a crash following a successful landing.\n\n" <>
       @project_options}
  end

  def render(["version"]), do: {0, "Usage: kogen version\n"}

  def render([topic]) when topic in ["help"],
    do: {0, "Usage: kogen help <command>\n\n#{@top_level}"}

  def render(topic), do: {2, "kogen: no help for #{Enum.join(topic, " ")}\n"}

  defp provider_account_help(verb) do
    {0,
     "Usage: kogen provider #{verb} chatgpt [--as <label>]\n\n" <>
       "    --as <label>  Kogen ChatGPT account label (default: default)\n"}
  end
end
