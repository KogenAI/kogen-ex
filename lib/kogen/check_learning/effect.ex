defmodule Kogen.CheckLearning.Effect do
  @moduledoc false
  alias Kogen.CheckLearning.Codec
  alias Kogen.CheckLearning.Store
  alias Kogen.State

  @spec record(Path.t(), Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def record(qualification, before_dir, after_dir) do
    with {:ok, bytes} <- File.read(qualification),
         {:ok, identity} <- Codec.qualification_identity(bytes),
         {:ok, before} <- build(before_dir),
         {:ok, checked} <- build(after_dir),
         true <- before.slug == checked.slug and before.intent_sha256 == checked.intent_sha256 do
      path =
        Path.join(Path.dirname(qualification), "build-effect-#{before.id}-#{checked.id}.json")

      effect = %{
        qualification_sha256: Store.digest(bytes),
        identity: identity,
        before: before,
        checked: checked,
        model_wall_ms_delta: checked.model_wall_ms - before.model_wall_ms,
        repair_delta: checked.repairs - before.repairs,
        interpretation:
          "measured comparison; model and base differences are retained, not a causal benefit claim"
      }

      with :ok <- Store.write(path, effect), do: {:ok, path}
    else
      false -> {:error, :build_effect_intent_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp build(directory) do
    root = directory |> Path.dirname() |> Path.dirname()

    with {:ok, run} <- State.load(root, Path.basename(directory)),
         true <- run.status in [:landed, :failed, :parked],
         {:ok, bytes} <- File.read(Path.join(run.dir, "events.jsonl")),
         {:ok, events} <- events(bytes) do
      {:ok,
       %{
         id: run.id,
         slug: run.slug,
         intent_sha256: run.intent_sha256,
         status: run.status,
         journal: run.dir,
         journal_sha256: Store.digest(bytes),
         base: value(events, :base_sha),
         approval: run.approval_commit,
         models: events |> Enum.map(& &1.model) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
         model_wall_ms:
           events
           |> Enum.filter(&(&1.event == "model_stage"))
           |> Enum.map(&(&1.wall_ms || 0))
           |> Enum.sum(),
         repairs: Enum.count(events, &(&1.event == "repair")),
         phase_wall_ms:
           events
           |> Enum.filter(&(&1.event == "phase_timing"))
           |> Enum.map(&(&1.wall_ms || 0))
           |> Enum.sum()
       }}
    else
      false -> {:error, :build_effect_requires_finished_builds}
      {:error, _reason} = error -> error
    end
  end

  defp events(bytes) do
    Enum.reduce_while(String.split(bytes, "\n", trim: true), {:ok, []}, fn line, {:ok, events} ->
      case State.decode_event(line) do
        {:ok, event} -> {:cont, {:ok, events ++ [event]}}
        error -> {:halt, error}
      end
    end)
  end

  defp value(events, key), do: Enum.find_value(events, &Map.get(&1, key))
end
