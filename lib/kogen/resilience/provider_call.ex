defmodule Kogen.Resilience.ProviderCall do
  @moduledoc """
  Runs one provider request in its own process, capped at `remaining_ms`. A crash or a stalled
  request becomes a classified `ProviderError`, so the retry policy treats it like any other
  transport failure and no raw exit reason ever reaches a journal or the terminal.

  Once the response has received bytes (the provider called the request's `on_progress`), it
  must keep receiving bytes: `idle_ms` without any is a `:stall`. Comments, keepalives and
  reasoning events all count. Before the first byte the outer cap applies, including provider
  setup and connection establishment.
  """

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Contracts.StreamProgress

  @spec run(
          module(),
          term(),
          ModelRequest.t(),
          non_neg_integer(),
          pos_integer() | :infinity,
          pos_integer()
        ) ::
          {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
  def run(
        provider_mod,
        config,
        request,
        remaining_ms,
        idle_ms \\ :infinity,
        first_byte_ms \\ 120_000
      )

  def run(_provider_mod, _config, _request, remaining_ms, _idle_ms, _first_byte_ms)
      when is_integer(remaining_ms) and remaining_ms <= 0, do: timeout_error()

  def run(provider_mod, config, %ModelRequest{} = request, remaining_ms, idle_ms, first_byte_ms) do
    caller = self()
    result_ref = make_ref()
    origin = now()
    progress = %{ref: :atomics.new(2, signed: false), origin: origin}
    byte = track_byte({caller, result_ref}, progress, request.on_byte)

    tracked = %{
      request
      | on_progress: track({caller, result_ref}, progress, request.on_progress),
        on_byte: byte,
        on_event: fn event -> send(caller, {result_ref, :event, event}) end
    }

    {worker, monitor} =
      spawn_monitor(fn ->
        Kogen.Contracts.WorkerGuard.watch(caller, self())

        send(
          caller,
          {result_ref, provider_mod.respond(config, tracked)}
        )
      end)

    timing = {origin + remaining_ms, idle_ms, progress, origin + first_byte_ms, %StreamProgress{}}
    await({result_ref, worker, monitor}, timing)
  end

  # Stores the latest progress as milliseconds since `origin`, plus one (0 means none yet). The
  # first progress wakes the caller so the idle timer starts; later ones only move it.
  defp track({caller, result_ref}, %{ref: ref, origin: origin}, callback) do
    fn ->
      track_byte({caller, result_ref}, %{ref: ref, origin: origin}, nil).()
      at = now() - origin + 1

      if :atomics.compare_exchange(ref, 1, 0, at) == :ok,
        do: send(caller, {result_ref, :progress}),
        else: :atomics.put(ref, 1, at)

      if is_function(callback, 0), do: callback.(), else: :ok
    end
  end

  defp track_byte({caller, result_ref}, %{ref: ref, origin: origin}, callback) do
    fn ->
      if :atomics.compare_exchange(ref, 2, 0, now() - origin + 1) == :ok,
        do: send(caller, {result_ref, :progress})

      if is_function(callback, 0), do: callback.(), else: :ok
    end
  end

  defp at(%{ref: ref, origin: origin}, index) do
    case :atomics.get(ref, index) do
      0 -> nil
      at -> origin + at - 1
    end
  end

  defp last_progress(progress), do: at(progress, 1) || at(progress, 2)

  defp await(call, timing) do
    if wait_ms(timing) == 0, do: expired(call, timing), else: receive_result(call, timing)
  end

  defp receive_result({result_ref, worker, monitor} = call, timing) do
    receive do
      {^result_ref, :progress} ->
        await(call, timing)

      {^result_ref, :event, event} ->
        partial = StreamProgress.feed(elem(timing, 4), event)
        await(call, put_elem(timing, 4, partial))

      {^result_ref, {:ok, %ModelResponse{} = response}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, response}

      {^result_ref, {:error, %ProviderError{} = error}} ->
        Process.demonitor(monitor, [:flush])
        with_partial({:error, error}, timing)

      {^result_ref, _invalid} ->
        Process.demonitor(monitor, [:flush])
        with_partial(provider_error(:malformed, "Provider returned an invalid response."), timing)

      # An exit reason can hold the HTTP request, headers included, so only its tag is kept.
      {:DOWN, ^monitor, :process, ^worker, reason} ->
        with_partial(
          provider_error(:transport, "Provider process failed: #{exit_tag(reason)}"),
          timing
        )
    after
      wait_ms(timing) -> expired(call, timing)
    end
  end

  # Wakes at the wall deadline or when the stream would have been idle for `idle_ms`.
  defp wait_ms({deadline, idle_ms, progress, first_deadline, _partial}) do
    wake =
      case {last_progress(progress), idle_ms} do
        {nil, _idle_ms} -> deadline
        {_last, :infinity} -> deadline
        {last, idle_ms} -> min(deadline, last + idle_ms)
      end

    wake = if at(progress, 2) == nil, do: min(wake, first_deadline), else: wake
    max(wake - now(), 0)
  end

  defp expired(
         {_ref, worker, monitor} = call,
         {deadline, idle_ms, progress, first_deadline, _partial} = timing
       ) do
    last = last_progress(progress)
    now = now()

    cond do
      now >= deadline ->
        stop(worker, monitor)
        with_partial(timeout_error(), timing)

      at(progress, 2) == nil and now >= first_deadline ->
        stop(worker, monitor)
        with_partial(provider_error(:timeout, "Provider first-byte deadline reached."), timing)

      last != nil and idle_ms != :infinity and now - last >= idle_ms ->
        stop(worker, monitor)
        with_partial(stall_error(now - last), timing)

      true ->
        await(call, timing)
    end
  end

  defp with_partial({:error, error}, {_deadline, _idle, progress, _first, partial}) do
    cut =
      if error.class in [:timeout, :stall, :transport, :malformed] and at(progress, 2),
        do: max(now() - progress.origin, 0)

    {:error, %{error | partial_items: StreamProgress.items(partial), cut_after_ms: cut}}
  end

  defp exit_tag(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp exit_tag({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp exit_tag(_reason), do: "abnormal exit"

  # `:shutdown` lets the worker's linked HTTP client stop quietly; a killed parent makes OTP
  # report the client's whole state, including the request's Authorization header.
  defp stop(worker, monitor) do
    Process.exit(worker, :shutdown)

    if await_down(worker, monitor, 1_000) == :timeout do
      Process.exit(worker, :kill)
      _ = await_down(worker, monitor, 1_000)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_down(worker, monitor, timeout_ms) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      timeout_ms -> :timeout
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp timeout_error,
    do: provider_error(:timeout, "Harness wall deadline reached during provider request.")

  defp stall_error(idle_ms),
    do:
      provider_error(
        :stall,
        "Provider stream sent nothing for #{div(idle_ms, 1_000)} s after it started."
      )

  defp provider_error(class, message),
    do: {:error, %ProviderError{class: class, message: message}}
end
