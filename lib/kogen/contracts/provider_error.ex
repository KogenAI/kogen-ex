defmodule Kogen.Contracts.ProviderError do
  @moduledoc """
  A classified, recoverable error returned by a model provider. `:stall` is a streaming
  response that went silent after it started; it is retried like any other transport failure.
  """

  @enforce_keys [:class, :message]
  defstruct @enforce_keys

  @type class ::
          :login | :usage_limit | :overload | :timeout | :stall | :malformed | :transport
  @type t :: %__MODULE__{class: class(), message: String.t()}
end
