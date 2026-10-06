defmodule Kogen.Kernel.CLI.StatusOutput do
  @moduledoc """
  Readable status: the queue first, then Intents grouped by state. Building Intents show
  their stage and elapsed time, failed ones the reason, landed ones the five most recent.
  """

  alias Kogen.Queue.BuildSummary
  alias Kogen.Queue.IntentStatus
  alias Kogen.Queue.Status

  @landed_shown 5

  @spec text(%{statuses: [IntentStatus.t()], queue: term()}, integer()) :: String.t()
  def text(%{statuses: statuses, queue: queue}, now) do
    queued = Status.queued(statuses)
    by_state = Enum.group_by(statuses, & &1.status)

    sections = [
      section("Building", Map.get(by_state, :building, []), &building_row(&1, now)),
      section("Queued", queued, &{&1.slug, nil}),
      section("Failed", Map.get(by_state, :failed, []), &stopped_row/1),
      section("Parked", Map.get(by_state, :parked, []), &stopped_row/1),
      section("Interrupted", Map.get(by_state, :interrupted, []), &stopped_row/1),
      section("Drafts", Map.get(by_state, :draft, []), &{&1.slug, nil}),
      landed_section(Map.get(by_state, :landed, []))
    ]

    body = if statuses == [], do: "No Intents.\n", else: Enum.join(sections)
    queue_line(queue, length(queued)) <> body
  end

  @spec intent_text(IntentStatus.t(), non_neg_integer() | nil, non_neg_integer(), integer()) ::
          String.t()
  def intent_text(%IntentStatus{} = status, position, queued, now) do
    "#{status.slug}: " <> state_text(status, position, queued, now) <> "\n"
  end

  @spec build_text(BuildSummary.t() | nil) :: String.t()
  def build_text(nil), do: ""

  def build_text(%BuildSummary{} = build) do
    outcome =
      if build.reason, do: "#{build.run_status}, #{build.reason}", else: "#{build.run_status}"

    stages =
      if build.stages == [],
        do: "",
        else:
          "  model time: " <>
            Enum.map_join(build.stages, ", ", fn {stage, ms} ->
              "#{stage} #{duration(div(ms, 1000))}"
            end) <>
            "\n"

    diff = if build.candidate_diff, do: "  candidate diff: #{build.candidate_diff}\n", else: ""

    "Build #{short(build.build_id)}: #{outcome}\n" <>
      stages <>
      continuations(build.continuations) <>
      progress_text(build.progress) <> diff <> "  journal: #{build.journal}\n"
  end

  defp progress_text(nil), do: ""

  defp progress_text(%{verified: verified, remaining: remaining}) do
    "  acceptance verified: #{Enum.join(verified, ", ")}\n" <>
      "  acceptance remaining: #{Enum.join(remaining, ", ")}\n"
  end

  defp continuations(0), do: ""

  defp continuations(count),
    do: "  context continuations: #{count} (same approved Build; checkpoints in journal)\n"

  @doc "JSON Lines: one object per Intent."
  @spec json([IntentStatus.t()]) :: String.t()
  def json(statuses), do: Enum.map_join(statuses, &(intent_json(&1) <> "\n"))

  @spec intent_json(IntentStatus.t()) :: String.t()
  def intent_json(status), do: status |> record() |> :json.encode() |> IO.iodata_to_binary()

  defp record(status) do
    Map.new([
      {"slug", status.slug},
      {"status", Atom.to_string(status.status)},
      {"build_id", json_value(status.run_id)},
      {"landed_sha", json_value(status.landed_sha)}
    ])
  end

  defp queue_line({:running, pid}, _queued), do: "Queue: running (pid #{pid})\n"
  defp queue_line(_stopped, 0), do: "Queue: stopped\n"

  defp queue_line(_stopped, queued),
    do: "Queue: stopped, #{queued} waiting; start it with kogen queue start\n"

  defp state_text(%{status: :approved}, position, queued, _now) when is_integer(position),
    do: "queued, #{position + 1} of #{queued}"

  defp state_text(%{status: :building} = status, _position, _queued, now),
    do: "building, " <> building_detail(status, now)

  defp state_text(%{status: :landed} = status, _position, _queued, _now),
    do: "landed #{short(status.landed_sha)}"

  defp state_text(%{status: :draft, slug: slug}, _position, _queued, _now),
    do: "draft; review it with kogen intent approve #{slug}"

  defp state_text(%{status: state} = status, _position, _queued, _now),
    do: "#{state}" <> if(status.detail, do: ", #{status.detail}", else: "")

  defp section(_title, [], _row), do: ""

  defp section(title, statuses, row) do
    rows = Enum.map(statuses, row)
    width = rows |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max()
    "#{title}:\n" <> Enum.map_join(rows, &row_line(&1, width))
  end

  defp landed_section([]), do: ""

  defp landed_section(statuses) do
    recent = statuses |> Enum.sort_by(&(&1.landed_index || 0)) |> Enum.take(@landed_shown)
    rows = Enum.map(recent, &{&1.slug, short(&1.landed_sha)})
    width = rows |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max()
    earlier = length(statuses) - length(recent)
    more = if earlier > 0, do: "  and #{earlier} earlier\n", else: ""
    "Landed (#{length(statuses)}):\n" <> Enum.map_join(rows, &row_line(&1, width)) <> more
  end

  defp row_line({slug, nil}, _width), do: "  #{slug}\n"
  defp row_line({slug, detail}, width), do: "  #{String.pad_trailing(slug, width)}  #{detail}\n"

  defp building_row(status, now), do: {status.slug, building_detail(status, now)}

  defp building_detail(status, now) do
    elapsed = if status.started_at, do: ", #{duration(now - status.started_at)}", else: ""
    "#{status.detail || "starting"}#{elapsed}#{build_ref(status)}"
  end

  defp stopped_row(status), do: {status.slug, "#{status.detail || "unknown"}#{build_ref(status)}"}

  defp build_ref(%{run_id: nil}), do: ""
  defp build_ref(%{run_id: run_id}), do: " (Build #{short(run_id)})"

  defp duration(seconds) when seconds < 60, do: "#{max(seconds, 0)}s"
  defp duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"

  defp duration(seconds),
    do: "#{div(seconds, 3600)}h#{seconds |> rem(3600) |> div(60) |> pad2()}m"

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp short(nil), do: "-"
  defp short(value), do: String.slice(value, 0, 8)

  defp json_value(nil), do: :null
  defp json_value(value), do: value
end
