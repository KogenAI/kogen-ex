defmodule Kogen.Quality.Source.Scope do
  @moduledoc false
  @enforce_keys [:filename, :root]
  defstruct @enforce_keys ++
              [
                attributes: %{},
                variables: %{},
                aliases: %{},
                imports: [],
                resources: MapSet.new(),
                reads: []
              ]
end
