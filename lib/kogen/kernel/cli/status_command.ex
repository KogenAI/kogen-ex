defmodule Kogen.Kernel.CLI.StatusCommand do
  @moduledoc false

  alias Kogen.Agents.Output, as: AgentOutput
  alias Kogen.Cli.Args
  alias Kogen.Contracts.Redact
  alias Kogen.Kernel.CLI.ErrorOutput
  alias Kogen.Kernel.CLI.StatusOutput
  alias Kogen.Queue.Status

  @poll_ms 2_000

  @spec run(Args.t()) :: {non_neg_integer(), String.t()}
  def run(%Args{} = args) do
    if File.dir?(args.project),
      do: dispatch(args),
      else: ErrorOutput.format({:project_unavailable, args.project})
  end

  defp dispatch(%Args{watch: true} = args), do: watch(args, nil)

  defp dispatch(%Args{} = args) do
    case view(args) do
      {:ok, view} -> {0, render(view, args)}
      {:error, reason} -> ErrorOutput.format(reason)
    end
  end

  # Prints whenever the view changes and returns once no Build runs and the queue is stopped.
  defp watch(args, last) do
    case view(args) do
      {:ok, view} ->
        text = render(view, args)
        if text != last, do: IO.write(Redact.text(if(last, do: "\n" <> text, else: text)))

        if idle?(view) do
          {watch_code(view), ""}
        else
          receive do
          after
            @poll_ms -> watch(args, text)
          end
        end

      {:error, reason} ->
        ErrorOutput.format(reason)
    end
  end

  defp idle?(%{overview: overview}),
    do:
      overview.queue == :stopped and not Enum.any?(overview.statuses, &(&1.status == :building)) and
        not Enum.any?(overview.agents, &(&1.status in ["running", "waiting"]))

  defp watch_code(%{intent: %{status: :landed}}), do: 0
  defp watch_code(%{intent: _status}), do: 1
  defp watch_code(_view), do: 0

  defp view(%Args{positionals: []} = args) do
    with {:ok, overview} <- Kogen.Kernel.overview(args.project, args.origin, args.base) do
      {:ok, %{overview: overview}}
    end
  end

  defp view(%Args{positionals: [slug]} = args) do
    with {:ok, overview} <- Kogen.Kernel.overview(args.project, args.origin, args.base),
         {:ok, intent} <- find(overview.statuses, slug),
         {:ok, report} <- report(slug, args) do
      position = Enum.find_index(Status.queued(overview.statuses), &(&1.slug == slug))
      agents = Enum.filter(overview.agents, &(&1.build == intent.run_id))

      {:ok,
       %{overview: overview, intent: intent, position: position, report: report, agents: agents}}
    end
  end

  defp find(statuses, slug) do
    case Enum.find(statuses, &(&1.slug == slug)) do
      nil -> {:error, :intent_not_found}
      status -> {:ok, status}
    end
  end

  # --json prints the full Build report; text prints its summary.
  defp report(slug, %Args{json: true} = args) do
    case Kogen.Kernel.report(slug, args.project, args.origin, args.base) do
      {:ok, json} -> {:ok, json}
      {:error, :missing_run} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp report(slug, args),
    do: Kogen.Kernel.build_summary(slug, args.project, args.origin, args.base)

  defp render(%{intent: intent, report: report, agents: agents}, %Args{json: true}),
    do: AgentOutput.report(report || StatusOutput.intent_json(intent), agents) <> "\n"

  defp render(%{overview: overview}, %Args{positionals: [], json: true}),
    do: StatusOutput.json(overview.statuses) <> AgentOutput.json(overview.agents)

  defp render(%{intent: intent} = view, _args) do
    queued = length(Status.queued(view.overview.statuses))

    StatusOutput.intent_text(intent, view.position, queued, now()) <>
      StatusOutput.build_text(view.report) <> AgentOutput.text(view.agents)
  end

  defp render(%{overview: overview}, _args),
    do: StatusOutput.text(overview, now()) <> AgentOutput.text(overview.agents)

  defp now, do: System.os_time(:second)
end
