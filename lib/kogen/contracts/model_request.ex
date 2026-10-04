defmodule Kogen.Contracts.ModelRequest do
  @moduledoc "A provider-neutral request to a language model."

  @enforce_keys [:model, :effort, :instructions, :input, :tools, :previous_response_id]
  defstruct @enforce_keys ++ [prompt_cache_key: nil]

  @type t :: %__MODULE__{
          model: String.t(),
          effort: String.t(),
          instructions: String.t(),
          input: [map()],
          tools: [map()],
          previous_response_id: String.t() | nil,
          prompt_cache_key: String.t() | nil
        }
end
