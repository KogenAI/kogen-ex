defmodule Kogen.Contracts.Intent do
  @moduledoc "An approved, content-addressed Kogen Intent."

  alias Kogen.Contracts.AcceptanceItem

  @enforce_keys [:slug, :title, :size, :brief, :acceptance, :domains, :notes, :path, :sha256]
  defstruct @enforce_keys ++ [request: nil]

  @type size :: :small | :medium | :large
  @type t :: %__MODULE__{
          slug: String.t(),
          title: String.t(),
          size: size(),
          brief: String.t(),
          request: String.t() | nil,
          acceptance: [AcceptanceItem.t()],
          domains: [String.t()],
          notes: String.t() | nil,
          path: Path.t(),
          sha256: String.t()
        }
end
