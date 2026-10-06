defmodule Kogen.Agents.Store do
  @moduledoc false

  alias Kogen.Agents.Codec
  alias Kogen.Contracts.Redact

  @lease_ms 5_000

  def id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  def create(run_dir, record) do
    dir = Path.join([run_dir, "agents", record.id])

    with :ok <- File.mkdir_p(dir),
         :ok <- write(dir, record),
         :ok <- event(dir, record),
         do: {:ok, dir}
  end

  def write(dir, record) do
    path = Path.join(dir, "agent.json")
    temporary = path <> ".tmp"

    with :ok <- File.write(temporary, Codec.encode(record)),
         do: File.rename(temporary, path)
  end

  def event(dir, record) do
    File.write(Path.join(dir, "events.jsonl"), Redact.text(Codec.encode(record)) <> "\n", [
      :append
    ])
  end

  def list(roots) do
    roots
    |> paths()
    |> Enum.flat_map(fn path ->
      case Codec.read(path) do
        {:ok, record} ->
          [
            record
            |> view()
            |> Map.put(:events_path, Path.join(Path.dirname(path), "events.jsonl"))
          ]

        {:error, reason} ->
          :logger.warning("Cannot read agent record ~ts: ~p", [path, reason])
          []
      end
    end)
    |> Enum.sort_by(&{&1.project, &1.build, &1.started_at, &1.id})
  end

  defp paths(roots),
    do:
      roots |> Enum.flat_map(&Path.wildcard(Path.join(&1, "agents/*/agent.json"))) |> Enum.uniq()

  defp view(record) do
    now = System.system_time(:millisecond)
    stale = record.status in ["running", "waiting"] and now - record.updated_at > @lease_ms
    ending = record.finished_at || now

    record
    |> Map.put(:status, if(stale, do: "stale", else: record.status))
    |> Map.put(:elapsed_ms, max(ending - record.started_at, 0))
  end
end
