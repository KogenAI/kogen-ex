defmodule Kogen.Contracts.Intent do
  @moduledoc """
  An approved, content-addressed Kogen Intent. `source: :raw` marks an Intent that is only the
  verbatim Request: it may have no Brief and no Acceptance items, and its gate is the
  project's own checks.
  """

  alias Kogen.Contracts.AcceptanceItem

  @enforce_keys [:slug, :title, :size, :brief, :acceptance, :domains, :notes, :path, :sha256]
  defstruct @enforce_keys ++ [request: nil, changes_gate: false, source: nil]

  @type size :: :small | :medium | :large
  @type t :: %__MODULE__{
          slug: String.t(),
          title: String.t(),
          size: size(),
          brief: String.t(),
          request: String.t() | nil,
          acceptance: [AcceptanceItem.t()],
          domains: [String.t()],
          changes_gate: boolean(),
          source: :raw | nil,
          notes: String.t() | nil,
          path: Path.t(),
          sha256: String.t()
        }
end
