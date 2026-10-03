defmodule Kogen.Contracts.ShapeWarning do
  @moduledoc "A deterministic warning produced while shaping an Intent."

  @enforce_keys [:code, :item_ids, :message]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          code: :shape_reclassified,
          item_ids: [String.t()],
          message: String.t()
        }
end
