defmodule Kogen.Quality.Source.Path do
  @moduledoc false

  @spec key(Macro.t(), map()) :: {:path, String.t()} | {:expression, String.t()}
  def key(ast, scope) do
    case value(ast, scope) do
      {:ok, path} when is_binary(path) -> {:path, Path.expand(path, scope.root)}
      _unknown -> {:expression, Macro.to_string(ast)}
    end
  end

  @spec value(Macro.t(), map()) :: {:ok, term()} | :unknown
  def value(value, _scope) when is_binary(value) or is_boolean(value) or is_nil(value),
    do: {:ok, value}

  def value({:__DIR__, _, _}, scope), do: {:ok, Path.dirname(Path.expand(scope.filename))}
  def value({:@, _, [{name, _, _}]}, scope), do: Map.get(scope.attributes, name, :unknown)

  def value({name, _, context}, scope) when is_atom(name) and is_atom(context),
    do: Map.get(scope.variables, name, :unknown)

  def value({:|>, _, [left, {call, meta, args}]}, scope) when is_list(args),
    do: value({call, meta, [left | args]}, scope)

  def value({:<>, _, [left, right]}, scope) do
    with {:ok, left} when is_binary(left) <- value(left, scope),
         {:ok, right} when is_binary(right) <- value(right, scope),
         do: {:ok, left <> right}
  end

  def value(list, scope) when is_list(list) do
    values = Enum.map(list, &value(&1, scope))

    if Enum.all?(values, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(values, &elem(&1, 1))},
      else: :unknown
  end

  def value({{:., _, [mod, function]}, _, args}, scope) do
    if module(mod, scope) == "Elixir.Path", do: path_call(function, args, scope), else: :unknown
  end

  def value(_ast, _scope), do: :unknown

  defp path_call(:join, [left, right], scope) do
    with {:ok, left} when is_binary(left) <- value(left, scope),
         {:ok, right} when is_binary(right) <- value(right, scope),
         do: {:ok, Path.join(left, right)}
  end

  defp path_call(:join, [parts], scope) do
    with {:ok, parts} when is_list(parts) <- value(parts, scope),
         true <- Enum.all?(parts, &is_binary/1),
         do: {:ok, Path.join(parts)}
  end

  defp path_call(:expand, [path], scope) do
    with {:ok, path} when is_binary(path) <- value(path, scope),
         do: {:ok, Path.expand(path, scope.root)}
  end

  defp path_call(:expand, [path, base], scope) do
    with {:ok, path} when is_binary(path) <- value(path, scope),
         {:ok, base} when is_binary(base) <- value(base, scope),
         do: {:ok, Path.expand(path, base)}
  end

  defp path_call(_function, _args, _scope), do: :unknown

  @spec module(Macro.t(), map()) :: String.t() | nil
  def module({:__aliases__, _, [name | tail]}, scope) do
    case Map.get(scope.aliases, name) do
      nil ->
        Enum.map_join(
          if(name == Elixir, do: [name | tail], else: [:"Elixir", name | tail]),
          ".",
          &Atom.to_string/1
        )

      target when tail == [] ->
        target

      target ->
        target <> "." <> Enum.map_join(tail, ".", &Atom.to_string/1)
    end
  end

  def module(_ast, _scope), do: nil

  @spec root(Path.t()) :: Path.t()
  def root(filename) do
    parts = filename |> Path.expand() |> Path.split()

    case Enum.find_index(parts, &(&1 in ["lib", "test", "src"])) do
      nil -> Path.dirname(Path.expand(filename))
      index -> parts |> Enum.take(index) |> Path.join()
    end
  end
end
