defmodule Kogen.Provider.ChatGPT.Lock do
  @moduledoc false

  alias Kogen.Contracts.Lock

  defdelegate with_lock(root, name, fun), to: Lock
  defdelegate with_lock(root, name, fun, opts), to: Lock
end
