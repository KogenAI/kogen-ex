defmodule Kogen.Project.SetupInputs do
  @moduledoc false

  @spec validate(term()) :: {nil | [String.t()], [map()]}
  def validate(nil), do: {nil, []}

  def validate(paths) when is_list(paths) and paths != [] do
    if Enum.all?(paths, &safe?/1) and length(Enum.uniq(paths)) == length(paths) do
      {paths, []}
    else
      error()
    end
  end

  def validate(_paths), do: error()

  @spec safe?(term()) :: boolean()
  def safe?(path) when is_binary(path) do
    path != "" and Path.type(path) == :relative and
      not String.contains?(path, [<<0>>, "\n", "\r"]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", "..", ".git"])) and
      not String.contains?(path, ["*", "?", "{", "}"])
  end

  def safe?(_path), do: false

  defp error do
    {nil,
     [
       %{
         line: nil,
         message: "`setup_inputs` must be a non-empty list of unique relative file paths"
       }
     ]}
  end
end
