defmodule Kogen.Kernel.CLI.QueueCommand do
  @moduledoc false

  alias Kogen.Cli.Args
  alias Kogen.Contracts.Redact
  alias Kogen.Kernel.CLI.ErrorOutput

  @spec start(Args.t()) :: {non_neg_integer(), String.t()}
  def start(%Args{detach: true} = args) do
    with :ok <- project_directory(args) do
      case Kogen.Kernel.queue_detach(args.project, args.origin, args.base) do
        {:ok, pid, log} -> {0, "queue: started in the background (pid #{pid})\nlog: #{log}\n"}
        {:running, pid} -> {0, "queue: already running (pid #{pid})\n"}
        {:error, reason} -> ErrorOutput.format(reason)
      end
    end
  end

  def start(%Args{} = args) do
    with :ok <- project_directory(args) do
      say = fn line -> IO.write(Redact.text(line)) end

      case Kogen.Kernel.queue_start(args.project, args.origin, args.base, say) do
        {:ok, summary} -> {exit_code(summary), summary_line(summary)}
        {:running, pid} -> {0, "queue: already running (pid #{pid})\n"}
        {:error, reason} -> ErrorOutput.format(reason)
      end
    end
  end

  @spec stop(Args.t()) :: {non_neg_integer(), String.t()}
  def stop(%Args{} = args) do
    with :ok <- project_directory(args) do
      case Kogen.Kernel.queue_stop(args.project, args.origin, args.base) do
        {:stopping, pid} -> {0, "queue: stopping after the current Build (pid #{pid})\n"}
        :not_running -> {0, "queue: not running\n"}
        {:error, reason} -> ErrorOutput.format(reason)
      end
    end
  end

  defp exit_code(%{stop: {:failed, outcome}}), do: class_code(outcome.class)

  defp exit_code(%{builds: builds}),
    do: if(Enum.all?(builds, &(&1.status == :landed)), do: 0, else: 1)

  defp class_code(:environment), do: 3
  defp class_code(:provider), do: 4
  defp class_code(_class), do: 70

  defp summary_line(%{builds: [], stop: :empty}), do: "queue: nothing to build\n"

  defp summary_line(%{builds: builds, stop: :empty}), do: "queue: done; #{counts(builds)}\n"

  defp summary_line(%{builds: builds, stop: :requested}),
    do: "queue: stopped on request; #{counts(builds)}\n"

  defp summary_line(%{builds: builds, stop: {:failed, outcome}}),
    do: "queue: stopped because #{outcome.slug} hit a #{outcome.class} error; #{counts(builds)}\n"

  defp counts(builds) do
    landed = Enum.count(builds, &(&1.status == :landed))
    "#{length(builds)} Build(s), #{landed} landed, #{length(builds) - landed} not"
  end

  defp project_directory(%Args{project: project}) do
    if File.dir?(project),
      do: :ok,
      else: ErrorOutput.format({:project_unavailable, project})
  end
end
