defmodule Kogen.Resilience.Policy do
  @moduledoc """
  Explicit provider-resilience configuration for one run.

  `fallbacks` lists, per role, the models to move to (in order) after the current model
  reports `overload_fallback_after` consecutive overloads.

  A request whose stream started but then sends nothing for `stream_idle_ms` is a stall: it is
  aborted and retried. Live Responses streams send a reasoning item every 9–20 s while the
  model thinks, so 90 s of silence is far beyond a legitimate pause. Hard turns reason for over
  10 minutes, so `request_cap_ms` (20 minutes) is only a last-resort cap on one attempt.
  Timeouts, stalls and transport failures are retried for as long as the wall budget lasts;
  `max_attempts` bounds the other retried classes, and every class when there is no budget.
  """

  alias Kogen.Contracts.ProviderError

  @retryable [:timeout, :stall, :transport, :overload, :malformed]
  @budget_bound [:timeout, :stall, :transport]
  @sol_medium {"gpt-6.1-sol", "medium"}

  defstruct max_attempts: 4,
            backoff_base_ms: 2_000,
            backoff_max_ms: 60_000,
            request_cap_ms: 1_200_000,
            stream_idle_ms: 90_000,
            overload_fallback_after: 2,
            fallbacks: %{
              builder: [@sol_medium],
              context: [@sol_medium],
              planner: [@sol_medium],
              reviewer: [@sol_medium]
            }

  @type model :: {String.t(), String.t()}
  @type role :: :builder | :context | :planner | :reviewer
  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          backoff_base_ms: non_neg_integer(),
          backoff_max_ms: non_neg_integer(),
          request_cap_ms: pos_integer(),
          stream_idle_ms: pos_integer(),
          overload_fallback_after: pos_integer(),
          fallbacks: %{optional(role()) => [model()]}
        }

  @doc "Login and usage-limit errors can never succeed on retry, so only these classes are retried."
  @spec retryable?(ProviderError.class()) :: boolean()
  def retryable?(class), do: class in @retryable

  @doc "Classes retried for as long as the wall budget lasts, whatever `max_attempts` says."
  @spec budget_bound?(ProviderError.class()) :: boolean()
  def budget_bound?(class), do: class in @budget_bound

  @doc """
  Errors that no retry can fix but that clear by themselves or when the user signs in again:
  a Build waits them out instead of failing.
  """
  @spec waitable?(ProviderError.class()) :: boolean()
  def waitable?(class), do: class in [:usage_limit, :login]

  @doc "Maps an Exchange stage to the model role that serves it."
  @spec role(atom()) :: role()
  def role(:plan), do: :planner
  def role(:review), do: :reviewer
  def role(:context), do: :context
  def role(_stage), do: :builder

  @doc "Exponential backoff with jitter after `failed_attempts` failures: between half and all of the ceiling."
  @spec backoff_ms(t(), pos_integer()) :: non_neg_integer()
  def backoff_ms(%__MODULE__{} = policy, failed_attempts) when failed_attempts >= 1 do
    exponent = min(failed_attempts - 1, 20)
    ceiling = min(policy.backoff_base_ms * Integer.pow(2, exponent), policy.backoff_max_ms)
    half = div(ceiling, 2)
    half + if(ceiling - half > 0, do: :rand.uniform(ceiling - half), else: 0)
  end

  @doc "The first configured fallback for the role that is not the model already in use."
  @spec fallback(t(), role(), model()) :: model() | nil
  def fallback(%__MODULE__{} = policy, role, current) do
    policy.fallbacks
    |> Map.get(role, [])
    |> Enum.find(&(&1 != current))
  end
end
