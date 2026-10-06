# Run from the checkout: mise exec -- mix run docs/audits/styler/evidence.exs [output-dir]
defmodule StylerEvidence do
  @moduledoc false
  def run(output) do
    Application.load(:styler)
    File.mkdir_p!(output)
    {formatter, _binding} = Code.eval_file(".formatter.exs")

    files =
      formatter
      |> Keyword.fetch!(:inputs)
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.sort()

    rows = Enum.map(files, &file(&1, formatter))
    reproductions = Enum.map(examples(), &example(&1, formatter, output))

    report = %{
      schema: 1,
      checkout_version: Mix.Project.config()[:version],
      script_sha256: digest(File.read!(__ENV__.file)),
      elixir: System.version(),
      styler: :styler |> Application.spec(:vsn) |> to_string(),
      formatter_sha256: digest(File.read!(".formatter.exs")),
      file_count: length(rows),
      unchanged: Enum.count(rows, & &1.unchanged),
      idempotent: Enum.count(rows, & &1.idempotent),
      parseable: Enum.count(rows, & &1.parseable),
      failures: Enum.filter(rows, &Map.has_key?(&1, :error)),
      files: rows,
      reproductions: reproductions,
      scope:
        "Unchanged real inputs are byte-preserved. Executable examples prove only their listed input domains; AST differences require review, not a correctness finding."
    }

    File.write!(Path.join(output, "report.json"), Jason.encode!(report, pretty: true) <> "\n")

    IO.puts(
      "Styler #{report.styler}; Elixir #{report.elixir}; #{report.file_count} real inputs; #{report.unchanged} unchanged; #{report.idempotent} idempotent; #{report.parseable} parseable; #{length(report.failures)} failures."
    )

    Enum.each(
      reproductions,
      &IO.puts("#{&1.name}: #{&1.classification}; second_pass=#{&1.idempotent}")
    )
  end

  defp file(path, options) do
    input = File.read!(path)
    options = Keyword.merge(options, file: path, styler: [on_error: :raise])
    first = Styler.format(input, options)
    second = Styler.format(first, options)

    %{
      path: path,
      input_sha256: digest(input),
      first_sha256: digest(first),
      second_sha256: digest(second),
      unchanged: input == first,
      idempotent: first == second,
      parseable: match?({:ok, _}, Code.string_to_quoted(first)),
      ast_unchanged: ast(input) == ast(first)
    }
  rescue
    exception ->
      %{
        path: path,
        unchanged: false,
        idempotent: false,
        parseable: false,
        error: Exception.message(exception)
      }
  end

  defp example({name, input, values, kind}, options, output) do
    options =
      Keyword.merge(options,
        file: if(kind == :config, do: "config/config.exs", else: "example.exs"),
        styler: [on_error: :raise]
      )

    first = Styler.format(input, options)
    second = Styler.format(first, options)
    original_results = results(input, values, kind)
    rewritten_results = results(first, values, kind)
    preserved = original_results == rewritten_results

    for {suffix, text} <- [{"input", input}, {"first", first}, {"second", second}] do
      File.write!(Path.join(output, "#{name}.#{suffix}.exs.txt"), text)
    end

    %{
      name: name,
      inputs: inspect(values),
      before: original_results,
      after: rewritten_results,
      behavior_preserved: preserved,
      idempotent: first == second,
      changed: input != first,
      classification:
        if(preserved, do: "safe within exercised domain", else: "correctness counterexample")
    }
  rescue
    exception ->
      %{
        name: name,
        idempotent: false,
        behavior_preserved: false,
        classification: "formatter failure",
        error: Exception.message(exception)
      }
  end

  defp results(source, values, :function) do
    {function, _binding} = Code.eval_string(source)

    Enum.map(values, fn value ->
      try do
        inspect({:ok, function.(value)})
      rescue
        exception -> inspect({:raises, exception.__struct__})
      end
    end)
  end

  defp results(source, _values, :config) do
    config = Config.Reader.eval!("config/config.exs", source)
    [inspect(config)]
  end

  defp ast(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    Macro.prewalk(ast, fn
      {name, _metadata, args} -> {name, [], args}
      node -> node
    end)
  end

  defp digest(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)

  defp examples do
    [
      {"datetime-microsecond", "fn dt -> DateTime.add(dt, 1, :microsecond) end\n",
       [~U[2026-10-06 00:00:00Z], ~U[2026-10-06 00:00:00.123456Z]], :function},
      {"datetime-piped-microsecond", "fn dt -> dt |> DateTime.add(1, :microsecond) end\n",
       [~U[2026-10-06 00:00:00Z], ~U[2026-10-06 00:00:00.123456Z]], :function},
      {"large-number", "fn x -> x + 1000000 end\n", [0, 1, -1, 0.5], :function},
      {"map-construction", "fn pairs -> Enum.into(pairs, %{}) end\n", [[], [a: 1], [a: 1, a: 2]],
       :function},
      {"with-success-and-error",
       "fn value ->\n  with {:ok, x} <- value do\n    {:ok, x}\n  else\n    error -> error\n  end\nend\n",
       [{:ok, 1}, {:error, :missing}, nil], :function},
      {"strict-boolean-case",
       "fn value ->\n  case value do\n    true -> :ok\n    false -> :error\n  end\nend\n",
       [true, false, nil, :other], :function},
      {"duplicate-config-order",
       "import Config\nconfig :styler_probe, value: :z\nconfig :styler_probe, value: :a\n", [],
       :config},
      {"with-strict-true", "fn value -> with true <- value, do: :executed end\n",
       [true, false, nil, :ok], :function},
      {"with-binding-order",
       "fn value ->\n  x = :outer\n  result = with {:ok, x} <- value, true <- is_integer(x) do\n    {:ok, x}\n  else\n    _ -> {:error, x}\n  end\n  {result, x}\nend\n",
       [{:ok, 2}, {:ok, :bad}, {:error, :missing}], :function}
    ]
  end
end

StylerEvidence.run(List.first(System.argv()) || "docs/audits/styler/results")
