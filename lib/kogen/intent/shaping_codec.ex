defmodule Kogen.Intent.ShapingCodec do
  @moduledoc false

  alias Kogen.Contracts.ShapingCheck

  @spec parse(map()) :: {:ok, [map()], [String.t()]} | {:error, [map()]}
  def parse(attrs) do
    assumptions = Map.get(attrs, "assumptions", [])
    contracts = Map.get(attrs, "shared_contracts", [])
    dependencies = Map.get(attrs, "blocks_on", [])

    cond do
      not (valid_checks?(assumptions) and valid_checks?(contracts) and is_list(dependencies)) ->
        error("shaping checks require name, path and contains; blocks_on requires Intent slugs")

      Enum.any?(dependencies, &(not slug?(&1))) ->
        invalid = Enum.reject(dependencies, &slug?/1)
        names = Enum.map_join(invalid, ", ", &dependency_name/1)
        error("invalid dependencies: #{names}; blocks_on requires Intent slugs")

      true ->
        checks = tag(assumptions, "assumption") ++ tag(contracts, "shared contract")
        {:ok, checks, dependencies}
    end
  end

  defp dependency_name(slug) when is_binary(slug), do: slug
  defp dependency_name(value), do: inspect(value)
  defp error(message), do: {:error, [%{line: 2, message: message}]}

  defp tag(checks, kind) do
    Enum.map(checks, fn check ->
      %ShapingCheck{
        kind: kind,
        name: check["name"],
        path: check["path"],
        contains: check["contains"]
      }
    end)
  end

  defp valid_checks?(checks) when is_list(checks) do
    Enum.all?(checks, fn
      %{"name" => name, "path" => path, "contains" => text} = check ->
        check |> Map.keys() |> Enum.sort() == ~w(contains name path) and
          nonempty?(name) and safe_path?(path) and nonempty?(text)

      _check ->
        false
    end)
  end

  defp valid_checks?(_checks), do: false
  defp nonempty?(text), do: is_binary(text) and String.trim(text) != ""

  defp safe_path?(path) when is_binary(path) do
    Path.type(path) == :relative and not String.contains?(path, <<0>>) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", "..", ".git"]))
  end

  defp safe_path?(_path), do: false
  defp slug?(slug), do: is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)
end
