defmodule Kogen.Contracts.ModelRequest do
  @moduledoc """
  A provider-neutral request to a language model. A streaming provider calls `on_progress`
  on every nonempty raw response chunk, including SSE comments, keepalives and reasoning
  events, so the caller can time the first byte and notice a stream that went silent.
  """

  @enforce_keys [:model, :effort, :instructions, :input, :tools, :previous_response_id]
  defstruct @enforce_keys ++
              [
                prompt_cache_key: nil,
                on_progress: nil,
                adapter: :responses,
                text_verbosity: nil,
                reasoning_summary: :auto,
                reasoning_context: nil,
                tool_choice: :auto,
                parallel_tool_calls: false,
                session_id: nil
              ]

  @type t :: %__MODULE__{
          model: String.t(),
          effort: String.t(),
          instructions: String.t(),
          input: [map()],
          tools: [map()],
          previous_response_id: String.t() | nil,
          prompt_cache_key: String.t() | nil,
          adapter: :responses | :lite,
          text_verbosity: nil | :low | :medium | :high,
          reasoning_summary: :none | :auto | :concise | :detailed,
          reasoning_context: nil | :all_turns,
          tool_choice: :auto | :none | :required,
          parallel_tool_calls: boolean(),
          session_id: String.t() | nil,
          on_progress: (-> :ok) | nil
        }
end
