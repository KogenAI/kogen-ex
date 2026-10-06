defmodule Kogen.Kernel.CLI.CheckProposals do
  @moduledoc false
  alias Kogen.Cli.Args

  @spec run(Args.t()) :: {non_neg_integer(), String.t()}
  def run(%Args{command: :checks_effect, positionals: [report, before, checked]}) do
    case Kogen.CheckLearning.record_effect(
           Path.expand(report),
           Path.expand(before),
           Path.expand(checked)
         ) do
      {:ok, path} -> {0, "Measured Build comparison: #{path}\n"}
      {:error, reason} -> {1, "check proposal: #{inspect(reason)}\n"}
    end
  end

  def run(%Args{positionals: [proposal, spec], project: root}) do
    with {:ok, runtime} <- Kogen.Kernel.runtime(),
         {:ok, result} <-
           Kogen.CheckLearning.qualify(
             Path.expand(proposal),
             Path.expand(spec),
             root,
             runtime.base_env
           ) do
      decision =
        if result.adoption_ready do
          "Draft adoption Intent: #{result.adoption_intent}\nCaller must shape and approve this individual protected rule.\n"
        else
          "Precision or contrasting examples need more work before proposing adoption.\n"
        end

      {0,
       "Precision sample: #{result.report}\n" <>
         decision <> "Mining enabled no blocking gate.\n"}
    else
      {:error, reason} ->
        {1, "check proposal: #{inspect(reason)}\n"}
    end
  end
end
