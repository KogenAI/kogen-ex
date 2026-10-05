defmodule Kogen.Build.Cycle.ProviderFailure do
  @moduledoc false

  @provider_retries 2
  # The exchange already retried timeouts inside the wall budget; repeating the whole stage would
  # only spend a fresh budget. Login and usage-limit errors cannot succeed on retry.
  @retryable [:transport, :overload, :malformed]

  def retry(state, stage, reason) do
    if reason not in @retryable or state.provider_retries >= @provider_retries do
      {:stop, {:provider_retries_exhausted, reason}}
    else
      retry_stage(state, stage, reason)
    end
  end

  defp retry_stage(state, stage, reason) do
    {state_stage, run_stage} = retry_target(stage)
    retries = state.provider_retries + 1
    next = %{state | stage: state_stage, provider_retries: retries, pending_land: false}

    args = %{
      approval: next.approval,
      repairs_left: next.repairs_left,
      provider_retries: retries,
      attempt: next.attempt,
      provider_retry: retries
    }

    {:retry, next,
     [
       {:record, %{event: :provider_retry, stage: stage, reason: reason}},
       {:run, run_stage, args}
     ]}
  end

  defp retry_target(stage) when stage in [:commit, :land], do: {:commit, :commit}
  defp retry_target(stage), do: {stage, stage}
end
