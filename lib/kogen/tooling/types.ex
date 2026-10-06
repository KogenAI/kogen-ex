defmodule Kogen.Tooling.ToolArgs do
  @moduledoc false

  @enforce_keys [:name]
  defstruct [
    :name,
    :path,
    :pattern,
    :offset,
    :limit,
    :old_text,
    :new_text,
    :content,
    :cmd,
    :handle,
    :tool_result_tokens,
    :output_offset,
    :output_limit
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          path: String.t() | nil,
          pattern: String.t() | nil,
          offset: pos_integer() | nil,
          limit: pos_integer() | nil,
          old_text: String.t() | nil,
          new_text: String.t() | nil,
          content: String.t() | nil,
          cmd: String.t() | nil,
          handle: String.t() | nil,
          tool_result_tokens: pos_integer() | nil,
          output_offset: non_neg_integer() | nil,
          output_limit: pos_integer() | nil
        }
end

defmodule Kogen.Tooling.Error do
  @moduledoc false

  @enforce_keys [:reason, :detail]
  defstruct @enforce_keys

  @type t :: %__MODULE__{reason: atom(), detail: String.t()}
end

defmodule Kogen.Tooling.ToolResult do
  @moduledoc false

  @enforce_keys [:output, :is_error, :paths]
  defstruct @enforce_keys ++ [receipt: nil]

  @type t :: %__MODULE__{
          receipt: map() | nil,
          output: String.t(),
          is_error: boolean(),
          paths: [Path.t()]
        }
end
