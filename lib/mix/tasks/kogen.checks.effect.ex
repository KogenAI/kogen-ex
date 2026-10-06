defmodule Mix.Tasks.Kogen.Checks.Effect do
  @shortdoc "Retains measured Build comparisons for check qualification"
  @moduledoc "Repository tooling: mix kogen.checks.effect <qualification.json> <before-run> <checked-run>."
  use Mix.Task
  use Boundary, classify_to: Kogen.Mix

  @impl Mix.Task
  def run([report, before, checked]) do
    case Kogen.CheckLearning.record_effect(
           Path.expand(report),
           Path.expand(before),
           Path.expand(checked)
         ) do
      {:ok, path} -> Mix.shell().info("Measured Build comparison: #{path}")
      {:error, reason} -> Mix.raise("check proposal: #{inspect(reason)}")
    end
  end

  def run(_args),
    do:
      Mix.raise("Usage: mix kogen.checks.effect <qualification.json> <before-run> <checked-run>")
end
