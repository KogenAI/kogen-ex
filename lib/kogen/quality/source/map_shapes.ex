defmodule Kogen.Quality.Source.MapShapes do
  @moduledoc "Suggests structs for repeated bare maps exposed by public functions."

  @spec analyze([{Path.t(), Macro.t()}]) :: [{Path.t(), pos_integer(), String.t()}]
  def analyze(sources) do
    counts =
      sources
      |> Enum.flat_map(fn {_file, ast} -> maps(ast) end)
      |> Enum.frequencies_by(&elem(&1, 1))

    sources
    |> Enum.flat_map(fn {file, ast} ->
      for {line, keys} <- public_maps(ast), Map.get(counts, keys, 0) >= 3 do
        {file, line,
         "Replace the repeated #{inspect(keys)} bare map with a struct for this public contract."}
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp maps({:quote, _, _}), do: []

  defp maps({:@, _, [{name, _, _}]})
       when name in [:type, :typep, :opaque, :spec, :doc, :moduledoc], do: []

  defp maps({:%, _, [_struct, {:%{}, _, entries}]}),
    do: Enum.flat_map(entries, fn {_key, value} -> maps(value) end)

  defp maps({:%{}, meta, entries}) do
    own =
      case keys(entries) do
        nil -> []
        keys -> [{meta[:line], keys}]
      end

    own ++ Enum.flat_map(entries, &maps/1)
  end

  defp maps({_kind, _meta, args}) when is_list(args), do: Enum.flat_map(args, &maps/1)
  defp maps({_key, value}), do: maps(value)
  defp maps(list) when is_list(list), do: Enum.flat_map(list, &maps/1)
  defp maps(_ast), do: []

  defp keys(entries) do
    if length(entries) >= 4 and Enum.all?(entries, &atom_entry?/1),
      do: entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() |> enough_keys()
  end

  defp enough_keys(keys) when length(keys) >= 4, do: keys
  defp enough_keys(_keys), do: nil
  defp atom_entry?({key, _value}), do: is_atom(key)
  defp atom_entry?(_entry), do: false

  defp public_maps({:quote, _, _}), do: []

  defp public_maps({:def, _, [head, body]}) do
    maps(head) ++ returns(Keyword.get(body, :do))
  end

  defp public_maps({_kind, _meta, args}) when is_list(args),
    do: Enum.flat_map(args, &public_maps/1)

  defp public_maps({_key, value}), do: public_maps(value)
  defp public_maps(list) when is_list(list), do: Enum.flat_map(list, &public_maps/1)
  defp public_maps(_ast), do: []

  defp returns({:__block__, _, forms}), do: forms |> List.last() |> returns()

  defp returns({kind, _, args}) when kind in [:if, :unless, :case, :cond, :with, :try] do
    args |> List.last() |> branches()
  end

  defp returns({:->, _, [_patterns, body]}), do: returns(body)
  defp returns({:fn, _, _}), do: []
  defp returns({:quote, _, _}), do: []
  defp returns({:%{}, _, _} = ast), do: maps(ast)
  defp returns({:{}, _, entries}), do: Enum.flat_map(entries, &returns/1)
  defp returns({tag, value}) when is_atom(tag), do: returns(value)
  defp returns(list) when is_list(list), do: Enum.flat_map(list, &returns/1)
  defp returns(_ast), do: []

  defp branches(keywords) when is_list(keywords) do
    Enum.flat_map(keywords, fn
      {key, value} when key in [:do, :else, :rescue, :catch] -> returns(value)
      _other -> []
    end)
  end

  defp branches(_ast), do: []
end
