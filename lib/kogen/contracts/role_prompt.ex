defmodule Kogen.Contracts.RolePrompt do
  @moduledoc "One no-tool model request for a named stage and model role."

  @enforce_keys [:stage, :role, :instructions, :text]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          stage: atom(),
          role: atom(),
          instructions: String.t(),
          text: String.t()
        }
end
