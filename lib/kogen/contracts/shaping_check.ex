defmodule Kogen.Contracts.ShapingCheck do
  @moduledoc "A named, observable product assumption or shared contract."
  @enforce_keys [:kind, :name, :path, :contains]
  defstruct @enforce_keys

  @type t :: %__MODULE__{kind: String.t(), name: String.t(), path: Path.t(), contains: String.t()}
end
