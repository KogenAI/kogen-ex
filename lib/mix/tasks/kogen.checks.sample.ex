defmodule Mix.Tasks.Kogen.Checks.Sample do
  @shortdoc "Qualifies candidate checks using labeled examples"
  @moduledoc "Repository tooling: mix kogen.checks.sample <proposal.json> <sample.json> --project <checkout>."
  use Mix.Task
  use Boundary, classify_to: Kogen.Mix

  @impl Mix.Task
  def run(args) do
    {options, paths, invalid} = OptionParser.parse(args, strict: [project: :string])

    case {paths, invalid, Keyword.get(options, :project)} do
      {[proposal, spec], [], root} when is_binary(root) and root != "" ->
        qualify(proposal, spec, Path.expand(root))

      _other ->
        Mix.raise(
          "Usage: mix kogen.checks.sample <proposal.json> <sample.json> --project <checkout>"
        )
    end
  end

  defp qualify(proposal, spec, root) do
    with {:ok, runtime} <- Kogen.Kernel.runtime(),
         {:ok, result} <-
           Kogen.CheckLearning.qualify(
             Path.expand(proposal),
             Path.expand(spec),
             root,
             runtime.base_env
           ) do
      Mix.shell().info("Precision sample: #{result.report}")

      if result.adoption_ready do
        Mix.shell().info("Draft adoption Intent: #{result.adoption_intent}")
        Mix.shell().info("Caller must shape and approve this individual protected rule.")
      else
        Mix.shell().info(
          "Precision or contrasting examples need more work before proposing adoption."
        )
      end

      Mix.shell().info("Mining enabled no blocking gate.")
    else
      {:error, reason} -> Mix.raise("check proposal: #{inspect(reason)}")
    end
  end
end
