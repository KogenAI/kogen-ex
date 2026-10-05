defmodule Kogen.Quality.Reach do
  @moduledoc false
  alias Kogen.Quality.Codec
  alias Kogen.Quality.Process, as: Command
  alias Kogen.Quality.Report
  alias Kogen.Quality.Snapshot

  @spec run(struct(), [Path.t()]) :: map()
  def run(request, paths) do
    with {:ok, directory} <- Snapshot.create(request, paths),
         {:ok, report} <-
           Command.json(
             request,
             ["mix", "reach.check", "--changed", "--base", request.base, "--format", "json"],
             directory
           ) do
      {downgrades, suppressions} = Codec.changes(report)
      Report.command("reach.check", downgrades(downgrades) ++ suppressions(suppressions))
    else
      {:error, reason} -> Report.skip("reach.check", reason)
    end
  end

  defp downgrades(items) do
    Enum.map(items, fn item ->
      Report.finding(
        "reach.check",
        "strictness_downgrade",
        item.file,
        item.line,
        "#{item.function}/#{item.arity} weakened required access to #{item.key}; fix callers or explicitly model the optional field."
      )
    end)
  end

  defp suppressions(items) do
    Enum.map(items, fn item ->
      severity = if item.reason, do: :warning, else: :error

      Report.finding(
        "reach.check",
        "new_suppression",
        item.file,
        item.line,
        "New Reach suppression; document its reason on the same line with -- reason.",
        severity
      )
    end)
  end
end
