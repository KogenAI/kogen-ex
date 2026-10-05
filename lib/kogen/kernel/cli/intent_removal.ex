defmodule Kogen.Kernel.CLI.IntentRemoval do
  @moduledoc false

  alias Kogen.Cli.Args
  alias Kogen.Kernel.CLI.ErrorOutput

  def run(%Args{} = args) do
    slug = hd(args.positionals)

    with :ok <- project_directory(args.project),
         {:ok, commit} <-
           Kogen.Kernel.remove_intent(
             slug,
             args.project,
             args.origin,
             args.base,
             args.force
           ) do
      {0, "removed: #{slug}\ncommit: #{commit}\n"}
    else
      {:error, reason} -> ErrorOutput.format(reason)
    end
  end

  defp project_directory(project) do
    if File.dir?(project), do: :ok, else: {:error, {:project_unavailable, project}}
  end
end
