defmodule Kogen.Quality.Clone do
  @moduledoc false
  @enforce_keys [:type, :snippets, :fragments]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Kogen.Quality.Fragment do
  @moduledoc false
  @enforce_keys [:file, :line]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Kogen.Quality.Change do
  @moduledoc false
  defstruct [:file, :line, :function, :arity, :key, :reason]
  @type t :: %__MODULE__{}
end

defmodule Kogen.Quality.Codec do
  @moduledoc false
  alias Kogen.Quality.Change
  alias Kogen.Quality.Clone
  alias Kogen.Quality.Fragment

  @spec clones(map()) :: [Clone.t()]
  def clones(%{"clones" => clones}) when is_list(clones) do
    Enum.map(clones, fn %{"type" => type, "snippets" => snippets, "fragments" => fragments} ->
      %Clone{
        type: type,
        snippets: snippets,
        fragments:
          Enum.map(fragments, fn %{"file" => file, "line" => line} ->
            %Fragment{file: file, line: line}
          end)
      }
    end)
  end

  @spec changes(map()) :: {[Change.t()], [Change.t()]}
  def changes(report) do
    downgrades =
      Enum.map(Map.get(report, "strictness_downgrades", []), fn item ->
        %Change{
          file: item["file"],
          line: item["new_line"],
          function: item["function"],
          arity: item["arity"],
          key: item["key"]
        }
      end)

    suppressions =
      report
      |> Map.get("suppression_report", %{})
      |> Map.get("added", [])
      |> Enum.map(fn item ->
        %Change{file: item["file"], line: item["line"], reason: item["reason"]}
      end)

    {downgrades, suppressions}
  end
end
