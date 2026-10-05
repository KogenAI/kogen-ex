defmodule Kogen.Quality.Source.ExternalResource do
  @moduledoc "Finds compile-time reads whose paths are not external resources."
  alias Kogen.Quality.Source.Path, as: Paths
  alias Kogen.Quality.Source.Scope

  @runtime [
    :def,
    :defp,
    :defmacro,
    :defmacrop,
    :defdelegate,
    :fn,
    :&,
    :test,
    :setup,
    :setup_all,
    :property
  ]
  @metadata [:doc, :moduledoc, :spec, :type, :typep, :opaque, :callback, :macrocallback]
  @reads [:read, :read!, :stream, :stream!]

  @spec analyze(Macro.t(), Path.t()) :: [{pos_integer(), String.t(), boolean()}]
  def analyze(ast, filename) do
    ast
    |> modules()
    |> Enum.flat_map(fn body ->
      scope = walk(body, %Scope{filename: filename, root: Paths.root(filename)})

      scope.reads
      |> Enum.reject(fn {_line, key} -> MapSet.member?(scope.resources, key) end)
      |> Enum.map(&finding(&1, scope))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp modules({:defmodule, _, [_name, [do: body]]}), do: [body | nested_modules(body)]
  defp modules({:__block__, _, forms}), do: Enum.flat_map(forms, &modules/1)
  defp modules(_ast), do: []

  defp nested_modules({kind, _, _}) when kind in @runtime or kind == :quote, do: []
  defp nested_modules({:defmodule, _, [_, [do: body]]}), do: [body | nested_modules(body)]

  defp nested_modules({_kind, _meta, args}) when is_list(args),
    do: Enum.flat_map(args, &nested_modules/1)

  defp nested_modules({_key, value}), do: nested_modules(value)
  defp nested_modules(list) when is_list(list), do: Enum.flat_map(list, &nested_modules/1)
  defp nested_modules(_ast), do: []

  defp walk({kind, _, _}, scope) when kind in @runtime or kind == :defmodule, do: scope

  defp walk({:quote, _, args}, scope) when is_list(args) do
    keywords = args |> Enum.filter(&is_list/1) |> List.flatten()
    walk(Keyword.get(keywords, :bind_quoted, []), scope)
  end

  defp walk({:@, _, [{name, _, _}]}, scope) when name in @metadata, do: scope

  defp walk({:@, _, [{:external_resource, _, [path]}]}, scope),
    do: %{scope | resources: MapSet.put(scope.resources, Paths.key(path, scope))}

  defp walk({:@, _, [{name, _, [value]}]}, scope) do
    next = walk(value, scope)
    %{next | attributes: Map.put(next.attributes, name, Paths.value(value, scope))}
  end

  defp walk({:=, _, [{name, _, context}, value]}, scope)
       when is_atom(name) and is_atom(context) do
    next = walk(value, scope)
    %{next | variables: Map.put(next.variables, name, Paths.value(value, scope))}
  end

  defp walk({kind, _, [condition, clauses]}, scope)
       when kind in [:if, :unless] and is_list(clauses) do
    case Paths.value(condition, scope) do
      {:ok, value} ->
        truthy? = value not in [false, nil]
        enabled? = if kind == :if, do: truthy?, else: not truthy?
        walk(Keyword.get(clauses, if(enabled?, do: :do, else: :else)), scope)

      _unknown ->
        walk([condition, clauses], scope)
    end
  end

  defp walk({:alias, _, [target | options]}, scope) do
    module = Paths.module(target, scope)
    opts = List.first(options) || []
    name = opts |> Keyword.get(:as, target) |> alias_name()
    if module && name, do: %{scope | aliases: Map.put(scope.aliases, name, module)}, else: scope
  end

  defp walk({:import, _, [target | options]}, scope) do
    if Paths.module(target, scope) == "Elixir.File",
      do: %{scope | imports: imported_reads(List.first(options) || [])},
      else: scope
  end

  defp walk({:|>, _, [left, {call, meta, args}]}, scope) when is_list(args),
    do: walk({call, meta, [left | args]}, scope)

  defp walk({{:., _, [mod, function]}, meta, args}, scope) when is_list(args) do
    module = Paths.module(mod, scope)
    next = record_read(module, function, meta, args, scope)
    next = walk(args, next)

    if module == "Elixir.Enum" and function in [:map, :each] do
      walk_callback(List.first(args), List.last(args), next)
    else
      next
    end
  end

  defp walk({function, meta, [path | _] = args}, scope) when function in @reads do
    next =
      if {function, length(args)} in scope.imports,
        do: record_read("Elixir.File", function, meta, args, scope),
        else: scope

    walk(path, next)
  end

  defp walk({_name, _meta, args}, scope) when is_list(args), do: walk(args, scope)
  defp walk(list, scope) when is_list(list), do: Enum.reduce(list, scope, &walk/2)
  defp walk({_key, value}, scope), do: walk(value, scope)
  defp walk(_ast, scope), do: scope

  defp walk_callback(collection, callback, scope) do
    case Paths.value(collection, scope) do
      {:ok, items} when is_list(items) ->
        Enum.reduce(items, scope, &invoke_callback(callback, &1, &2))

      _unknown ->
        scope
    end
  end

  defp invoke_callback({:fn, _, [{:->, _, [[{name, _, context}], body]}]}, item, scope)
       when is_atom(name) and is_atom(context) do
    inner = %{scope | variables: Map.put(scope.variables, name, {:ok, item})}
    result = walk(body, inner)
    %{scope | reads: result.reads, resources: result.resources}
  end

  defp invoke_callback(
         {:&, _, [{:/, _, [{{:., _, [mod, function]}, meta, []}, 1]}]},
         item,
         scope
       ), do: record_read(Paths.module(mod, scope), function, meta, [item], scope)

  defp invoke_callback(_callback, _item, scope), do: scope

  defp alias_name({:__aliases__, _, parts}), do: List.last(parts)
  defp alias_name(_ast), do: nil

  defp imported_reads(options) do
    reads = [
      read: 1,
      read!: 1,
      stream: 1,
      stream: 2,
      stream: 3,
      stream!: 1,
      stream!: 2,
      stream!: 3
    ]

    only = Keyword.get(options, :only, reads)
    except = Keyword.get(options, :except, [])
    if is_list(only), do: Enum.filter(reads, &(&1 in only and &1 not in except)), else: []
  end

  defp record_read("Elixir.File", function, meta, [path | _], scope) when function in @reads,
    do: %{scope | reads: [{meta[:line], Paths.key(path, scope)} | scope.reads]}

  defp record_read("Elixir.File", function, meta, [path | args], scope)
       when function in [:open, :open!] do
    if read_mode?(args),
      do: %{scope | reads: [{meta[:line], Paths.key(path, scope)} | scope.reads]},
      else: scope
  end

  defp record_read("Elixir.EEx", function, meta, args, scope)
       when function in [:compile_file, :eval_file, :function_from_file] do
    path = if function == :function_from_file, do: Enum.at(args, 2), else: List.first(args)
    %{scope | reads: [{meta[:line], Paths.key(path, scope)} | scope.reads]}
  end

  defp record_read(_module, _function, _meta, _args, scope), do: scope

  defp read_mode?([]), do: true
  defp read_mode?([{:fn, _, _} | _]), do: true

  defp read_mode?([options | _]) when is_list(options),
    do: :read in options or not (:write in options or :append in options)

  defp read_mode?(_args), do: false

  defp finding({line, {:path, path}}, scope) do
    path = Path.relative_to(path, scope.root)
    {line, "Declare @external_resource for #{path} so file edits recompile this module.", true}
  end

  defp finding({line, {:expression, expression}}, _scope) do
    {line, "Declare @external_resource for #{expression} so file edits recompile this module.",
     false}
  end
end
