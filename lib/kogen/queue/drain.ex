defmodule Kogen.Queue.Drain do
  @moduledoc """
  The serial drain behind `kogen queue start`: build the oldest approved Intent, repeat until
  none is left or a stop was requested. A Build that fails on its candidate or on a provider
  error doesn't stop the drain: its failure is recorded and the next Intent builds. When the
  provider cannot serve anyone (a usage limit or a lost login), the drain waits `pause_ms`
  and builds the same Intent again, for at most `pause_cap_ms` of waiting in all, as a ladder
  Build does. An environment or Kogen failure stops the drain, because the next Build would
  hit it too. Each step first recovers crashed Builds. Kernel supplies the effects as hooks;
  the optional `pause` hook waits (tests replace it).
  """

  alias Kogen.Queue.Lock
  alias Kogen.Queue.Status

  @type outcome :: %{
          slug: String.t(),
          status: :landed | :failed | :parked,
          run_id: String.t() | nil,
          landed_sha: String.t() | nil,
          class: atom() | nil,
          reason: String.t() | nil
        }

  @type hooks :: %{
          required(:recover) => (-> {:ok, list()} | {:error, term()}),
          required(:statuses) => (-> {:ok, [Kogen.Queue.IntentStatus.t()]} | {:error, term()}),
          required(:build) => (String.t() -> {:ok, outcome()} | {:error, term()}),
          required(:say) => (String.t() -> :ok),
          optional(:pause) => (pos_integer() -> :ok)
        }

  @pause_ms 300_000
  @pause_cap_ms 86_400_000
  @unavailable [{:provider, "usage_limit"}, {:provider, "login"}, {:environment, "login"}]

  @type summary :: %{builds: [outcome()], stop: :empty | :requested | {:failed, outcome()}}

  @spec run(Path.t(), hooks()) :: {:ok, summary()} | {:running, pos_integer()} | {:error, term()}
  def run(state_root, hooks) do
    case run_with_owner(state_root, hooks) do
      {:running, %{pid: pid}} -> {:running, pid}
      result -> result
    end
  end

  @doc "Runs the drain, returning the live owner's persisted metadata when already running."
  @spec run_with_owner(Path.t(), hooks()) ::
          {:ok, summary()}
          | {:running, %{pid: pos_integer(), started_at: String.t() | nil}}
          | {:error, term()}
  def run_with_owner(state_root, hooks) do
    case Lock.acquire_with_owner(state_root) do
      :ok ->
        try do
          loop(state_root, hooks, [], %{paused_ms: 0})
        after
          Lock.release(state_root)
        end

      other ->
        other
    end
  end

  defp loop(state_root, hooks, built, attempted) do
    with {:ok, _closed} <- hooks.recover.(),
         {:ok, statuses} <- hooks.statuses.() do
      next =
        statuses
        |> Status.queued()
        |> Enum.find(&(not Map.has_key?(attempted, attempt_key(&1))))

      cond do
        Lock.stop_requested?(state_root) -> {:ok, summary(built, :requested)}
        is_nil(next) -> {:ok, summary(built, :empty)}
        true -> step(state_root, hooks, next, built, Map.put(attempted, attempt_key(next), true))
      end
    end
  end

  defp step(state_root, hooks, next, built, attempted) do
    hooks.say.("building #{next.slug}\n")

    case hooks.build.(next.slug) do
      {:ok, outcome} ->
        hooks.say.(outcome_line(outcome))
        built = [outcome | built]

        cond do
          {outcome.class, outcome.reason} in @unavailable ->
            wait_for_provider(state_root, hooks, {next, outcome}, built, attempted)

          outcome.status == :failed and outcome.class in [:environment, :controller] ->
            {:ok, summary(built, {:failed, outcome})}

          true ->
            loop(state_root, hooks, built, attempted)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Nothing can build while the account is out, so after the wait the same Intent builds
  # again (its failed Build no longer leaves it queued).
  defp wait_for_provider(state_root, hooks, {next, outcome}, built, attempted) do
    if attempted.paused_ms + @pause_ms > @pause_cap_ms do
      {:ok, summary(built, {:failed, outcome})}
    else
      hooks.say.(
        "queue: the provider is unavailable (#{outcome.reason}); " <>
          "building #{next.slug} again in #{div(@pause_ms, 60_000)} min\n"
      )

      :ok = Map.get(hooks, :pause, &pause/1).(@pause_ms)
      attempted = %{attempted | paused_ms: attempted.paused_ms + @pause_ms}

      with {:ok, _closed} <- hooks.recover.() do
        if Lock.stop_requested?(state_root),
          do: {:ok, summary(built, :requested)},
          else: step(state_root, hooks, next, built, attempted)
      end
    end
  end

  defp pause(wait_ms) do
    receive do
    after
      wait_ms -> :ok
    end
  end

  # One attempt per approval per drain, so a Build that leaves no journal can't loop.
  defp attempt_key(status), do: {status.slug, status.approved_at}

  defp summary(built, stop), do: %{builds: Enum.reverse(built), stop: stop}

  @spec outcome_line(outcome()) :: String.t()
  def outcome_line(%{status: :landed} = outcome),
    do: "landed #{outcome.slug} #{short(outcome.landed_sha)}#{build_ref(outcome)}\n"

  def outcome_line(%{status: :parked} = outcome) do
    verdict = Map.get(outcome, :verdict, "unknown")

    "parked #{outcome.slug}: #{outcome.reason}; best candidate #{verdict} at " <>
      "refs/kogen/parked/#{outcome.run_id}#{build_ref(outcome)}\n"
  end

  def outcome_line(outcome) do
    cause = [outcome.class, outcome.reason] |> Enum.reject(&is_nil/1) |> Enum.join("/")
    "#{outcome.status} #{outcome.slug}: #{cause}#{build_ref(outcome)}\n"
  end

  defp build_ref(%{run_id: nil}), do: ""
  defp build_ref(%{run_id: run_id}), do: " (Build #{short(run_id)})"

  defp short(nil), do: "-"
  defp short(value), do: binary_part(value, 0, min(8, byte_size(value)))
end
