defmodule Kogen.Resilience.ProviderCall do
  @moduledoc """
  Runs one provider request in its own process, capped at `remaining_ms`. A crash or a stalled
  request becomes a classified `ProviderError`, so the retry policy treats it like any other
  transport failure and no raw exit reason ever reaches a journal or the terminal.
  """

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError

  @spec run(module(), term(), ModelRequest.t(), non_neg_integer()) ::
          {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
  def run(_provider_mod, _config, _request, remaining_ms)
      when is_integer(remaining_ms) and remaining_ms <= 0, do: timeout_error()

  def run(provider_mod, config, %ModelRequest{} = request, remaining_ms) do
    caller = self()
    result_ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn -> send(caller, {result_ref, provider_mod.respond(config, request)}) end)

    await(result_ref, worker, monitor, remaining_ms)
  end

  defp await(result_ref, worker, monitor, remaining_ms) do
    receive do
      {^result_ref, {:ok, %ModelResponse{} = response}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, response}

      {^result_ref, {:error, %ProviderError{} = error}} ->
        Process.demonitor(monitor, [:flush])
        {:error, error}

      {^result_ref, _invalid} ->
        Process.demonitor(monitor, [:flush])
        provider_error(:malformed, "Provider returned an invalid response.")

      # An exit reason can hold the HTTP request, headers included, so only its tag is kept.
      {:DOWN, ^monitor, :process, ^worker, reason} ->
        provider_error(:transport, "Provider process failed: #{exit_tag(reason)}")
    after
      remaining_ms ->
        stop(worker, monitor)
        timeout_error()
    end
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

  defp timeout_error,
    do: provider_error(:timeout, "Harness wall deadline reached during provider request.")

  defp provider_error(class, message),
    do: {:error, %ProviderError{class: class, message: message}}
end
