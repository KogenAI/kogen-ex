defmodule Kogen.Cli.Help do
  @moduledoc """
  Static help text. The top level lists commands and the shaping default; each
  command lists its own subcommands and options.
  """

  @top_level """
  Commands:
    status     Show the queue, Builds and Intents
    intent     Shape, approve or remove an Intent
    queue      Build approved Intents one at a time
    provider   Manage Kogen's provider logins
    version    Show the Kogen version
    help       List commands

  Intent shaping defaults to gpt-6.1-sol at high effort; an explicit build.roles.shaper
  in project or machine config overrides this default.

  Run kogen <command> to see its subcommands and options.
  """

  @project_options """
    --project <checkout>  Project checkout (default: current directory)
    --origin <repo>       Git repository holding Intent state and the target branch
    --base <branch>       Target branch (project setting, origin HEAD, then current branch)
  """

  @spec render([String.t()]) :: String.t()
  def render([]), do: @top_level

  def render(["status"]) do
    """
    Usage: kogen status [<slug>] [options]

    Shows the queue, then Intents by state. With <slug>, shows that Intent and its latest Build.
    Builds whose process died are marked crashed first. Agent roles, activity and elapsed
    time are shown for this project (with <slug>: its latest Build).

    Options:
      --watch               Print again on every change; return when the queue is idle
      --json                JSON Lines for Intents and agents (with <slug>: the Build report)
    #{@project_options}\
    """
  end

  def render(["intent"]) do
    """
    Usage: kogen intent <command> <slug> [arguments] [options]

    Commands:
      shape <slug> <file|->     Shape an Intent from a request file (- reads stdin)
      approve <slug> [<hash>]   Show the review card, or approve and queue the Intent
      remove <slug>            Remove an Intent and its approval in one commit
    """
  end

  def render(["intent", "shape"]) do
    """
    Usage: kogen intent shape <slug> <file|-> [options]

    Shapes .kogen/intents/<slug>/intent.md and its acceptance test from the request in <file>
    (- reads stdin). Waits until the shaper finishes, with no time limit. Never approves.
    Shaping defaults to gpt-6.1-sol at high effort. An explicit build.roles.shaper in
    project or machine config overrides this default.

    Options:
    #{@project_options}\
    """
  end

  def render(["intent", "approve"]) do
    """
    Usage: kogen intent approve <slug> [<hash>] [options]

    Without <hash>: runs the approval checks, prints the review card and exits 5.
    With <hash> (at least 6 characters of the card's SHA-256): records the approval, which
    queues the Intent. Approving never starts the queue; run kogen queue start.

    Options:
      --by <name>           Who approves, when not Git's user (e.g. an agent acting for you)
    #{@project_options}\
    """
  end

  def render(["intent", "remove"]) do
    """
    Usage: kogen intent remove <slug> [options]

    Removes the Intent files and its approval in one commit. An Intent in a running Build
    can't be removed.

    Options:
      --force               Confirm removing an approved (queued), failed or parked Intent
    #{@project_options}\
    """
  end

  def render(["queue"]) do
    """
    Usage: kogen queue <command> [options]

    Commands:
      start     Build approved Intents one at a time, oldest approval first
      stop      Stop the running queue after its current Build
    """
  end

  def render(["queue", "start"]) do
    """
    Usage: kogen queue start [options]

    Builds approved Intents one at a time, oldest approval first, until none are left, and
    prints a line as each Build starts and finishes. If the queue is already running, says so.
    Exit: 0 all landed; 1 a Build failed (the queue goes on); 3, 4 or 70 stopped on an
    environment, provider or Kogen error.

    Options:
      --detach              Run in the background; prints the process id and log path
    #{@project_options}\
    """
  end

  def render(["queue", "stop"]) do
    """
    Usage: kogen queue stop [options]

    Asks the running queue to stop after its current Build.

    Options:
    #{@project_options}\
    """
  end

  def render(["provider"]) do
    """
    Usage: kogen provider <command> [options]

    Commands:
      list               List saved accounts and the default
      login chatgpt      Sign in with a ChatGPT account
      login grok         Sign in with a Grok subscription
      logout chatgpt     Sign out of a ChatGPT account
      logout grok        Sign out of a Grok subscription
      use chatgpt        Choose the default account, or one project's account
      use grok           Choose the default account, or one project's account

    Logins belong to this machine, never to a repo.
    """
  end

  def render(["provider", "use"]) do
    """
    Usage: kogen provider use <provider> --as <label> [--project <checkout>]

    Supported providers: chatgpt, grok.
    Without --project: makes <label> the provider and account default on this machine.
    With --project: that project uses this provider and account; other projects keep their choice.
    Choices live in ~/.kogen/accounts.yaml on this machine, never in a repo.

    Options:
      --as <label>          Account label (required)
      --project <checkout>  The project that uses this account
    """
  end

  def render(["provider", "list"]),
    do:
      "Usage: kogen provider list\n\nLists saved accounts, whether each is signed in, " <>
        "and the default.\n"

  def render(["provider", verb]) when verb in ["login", "logout"] do
    """
    Usage: kogen provider #{verb} <provider>

    Supported providers: chatgpt, grok.
    """
  end

  def render(["version"]),
    do: "Usage: kogen version\n\nPrints the commit Kogen was built from and its date.\n"
end
