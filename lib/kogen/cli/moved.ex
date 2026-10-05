defmodule Kogen.Cli.Moved do
  @moduledoc """
  Old command and flag forms, kept for one CLI generation (5 Oct 2026) so callers learn the
  new form from a `moved:` line. Delete this module in the next generation.
  """

  @spec message([String.t()]) :: String.t() | nil
  def message(argv), do: command(argv) || flag(argv)

  defp command(["build", "show" | _rest]), do: "kogen status <slug>"
  defp command(["build" | _rest]), do: "kogen queue start (approved Intents build from the queue)"
  defp command(["report" | _rest]), do: "kogen status <slug>"
  defp command(["approve" | _rest]), do: "kogen intent approve <slug> <hash>"

  defp command(["reconcile" | _rest]),
    do: "kogen status (crash recovery is automatic in status and queue start)"

  defp command(["intent", "check" | _rest]),
    do: "kogen intent approve <slug> (prints the review card and check results)"

  defp command(["intent", "close" | _rest]), do: "kogen intent remove <slug>"
  defp command(["--version" | _rest]), do: "kogen version"
  defp command(_argv), do: nil

  defp flag(argv) do
    cond do
      option?(argv, "--task-file") ->
        "kogen intent shape <slug> <file>"

      option?(argv, "--yes") ->
        "kogen intent approve <slug> <hash>"

      option?(argv, "--borrow") ->
        "kogen provider login chatgpt for a Kogen-owned login"

      option?(argv, "--recipe") ->
        "build.recipe in .kogen/project.yaml"

      option?(argv, "--model") ->
        "build.roles.builder.model in .kogen/project.yaml"

      option?(argv, "--effort") ->
        "build.roles.builder.effort in .kogen/project.yaml"

      account_outside_provider?(argv) ->
        "kogen provider use chatgpt --as <label> --project <checkout>"

      true ->
        nil
    end
  end

  defp account_outside_provider?(["provider" | _rest]), do: false
  defp account_outside_provider?(argv), do: option?(argv, "--as")

  defp option?(argv, name),
    do: Enum.any?(argv, &(&1 == name or String.starts_with?(&1, name <> "=")))
end
