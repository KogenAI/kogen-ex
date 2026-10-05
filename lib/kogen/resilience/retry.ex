defmodule Kogen.Resilience.Retry do
  @moduledoc "Pure retry state for one model request: attempt count, overload streak and model."

  alias Kogen.Resilience.Policy

  @enforce_keys [:role, :model]
  defstruct @enforce_keys ++ [attempt: 1, overloads: 0]

  @type t :: %__MODULE__{
          role: Policy.role(),
          model: Policy.model(),
          attempt: pos_integer(),
          overloads: non_neg_integer()
        }

  @type decision ::
          {:retry, t(), delay_ms :: non_neg_integer(), fallback :: Policy.model() | nil}
          | :stop

  @spec new(Policy.role(), Policy.model()) :: t()
  def new(role, model), do: %__MODULE__{role: role, model: model}

  @doc """
  Decides what follows a failed attempt. Stops for non-retryable classes, when attempts are
  spent, or when the remaining wall budget cannot cover the backoff. After the configured
  overload streak the next configured model is used, without waiting.
  """
  @spec next(Policy.t(), t(), atom(), non_neg_integer() | :infinity) :: decision()
  def next(%Policy{} = policy, %__MODULE__{} = retry, class, remaining_ms) do
    if Policy.retryable?(class) and retry.attempt < policy.max_attempts do
      overloads = if class == :overload, do: retry.overloads + 1, else: 0
      switch(policy, retry, overloads, remaining_ms)
    else
      :stop
    end
  end

  defp switch(policy, retry, overloads, remaining_ms) do
    fallback =
      if overloads >= policy.overload_fallback_after,
        do: Policy.fallback(policy, retry.role, retry.model)

    delay = if fallback, do: 0, else: Policy.backoff_ms(policy, retry.attempt)

    if affordable?(delay, remaining_ms) do
      next = %{
        retry
        | attempt: retry.attempt + 1,
          overloads: if(fallback, do: 0, else: overloads),
          model: fallback || retry.model
      }

      {:retry, next, delay, fallback}
    else
      :stop
    end
  end

  defp affordable?(_delay, :infinity), do: true
  defp affordable?(delay, remaining_ms), do: remaining_ms > delay
end
