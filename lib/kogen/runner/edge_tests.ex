defmodule Kogen.Runner.EdgeTests do
  @moduledoc false

  # The edge-test writer's prompt, its reply, and per-test results from ExUnit output. The
  # writer sees only the verbatim Request and the project's module names: never the Intent's
  # Acceptance items, the plan, or a Candidate's code.

  @max_tests 20
  @extra_tag "kogen_edge_extra"
  @module_limit 300
  @failure_limit 8_000
  @test_line ~r/^(\s*)test\s+"((?:[^"\\]|\\.)*)"/
  @failure_header ~r/^\s+\d+\) test (.+) \(([^()]+)\)\s*$/m

  @instructions """
  You are Kogen's edge-test writer. Write black-box ExUnit tests for the change a Request describes. You have not seen any implementation, plan or other test of it. Write tests that every correct implementation of the Request must pass, focused on: boundaries; empty and invalid inputs; ordering; idempotence (doing the same thing twice); error returns; and every explicit constraint the Request states. Test only behaviour the Request specifies: do not assert exact error messages, output formatting, internal structure, timing or anything else the Request leaves open. Call only modules and functions the Request names or the project already has. Write at most 20 tests in one test module named KogenEdge.<a short name>Test, with no describe blocks and a unique name for every test; use the project's own test case templates when the tested code needs them. Return exactly one ```elixir fenced block holding the whole test file, and nothing else. You have no tools.
  """

  @type suite :: %{source: String.t(), names: [String.t()], generated: non_neg_integer()}

  @spec instructions() :: String.t()
  def instructions, do: @instructions

  @spec max_tests() :: pos_integer()
  def max_tests, do: @max_tests

  @doc "The writer's user message: the verbatim Request and the project's module names."
  @spec input(String.t(), [String.t()]) :: String.t()
  def input(request, modules) do
    String.trim("""
    Request (verbatim):
    #{String.trim(request)}

    Modules in the project's lib/ and test/support/ (names only):
    #{modules |> Enum.take(@module_limit) |> Enum.join("\n")}
    """)
  end

  @doc "Module names defined in `root`'s lib/ and test/support/ sources."
  @spec module_names(Path.t()) :: [String.t()]
  def module_names(root) do
    paths =
      Enum.flat_map(["lib/**/*.ex", "test/support/**/*.ex"], &Path.wildcard(Path.join(root, &1)))

    for_result =
      for path <- Enum.sort(paths),
          {:ok, source} <- [File.read(path)],
          [name] <- Regex.scan(~r/^\s*defmodule\s+([\w.]+)/m, source, capture: :all_but_first) do
        name
      end

    Enum.uniq(for_result)
  end

  @doc """
  The test file from the writer's reply. Tests past the 20th are tagged so the run excludes
  them; `names` lists the tests that run.
  """
  @spec parse(String.t()) :: {:ok, suite()} | {:error, atom()}
  def parse(text) when is_binary(text) do
    source = fenced(text)
    {lines, names} = tag_extra(String.split(source, "\n"))

    cond do
      not Regex.match?(~r/^\s*defmodule\s/m, source) -> {:error, :no_test_module}
      names == [] -> {:error, :no_tests}
      true -> {:ok, %{source: Enum.join(lines, "\n"), names: names, generated: length(names)}}
    end
  end

  @doc "The arguments that leave out tests past the cap."
  @spec run_arguments() :: [String.t()]
  def run_arguments, do: ["--exclude", @extra_tag]

  @doc """
  The names among `names` that failed in `output`; every name when the run did not finish with
  a summary or some tests were invalidated.
  """
  @spec failed(String.t(), [String.t()], {non_neg_integer(), non_neg_integer()} | nil) ::
          [String.t()]
  def failed(_output, names, nil), do: names

  def failed(output, names, _summary) do
    if Regex.match?(~r/[1-9]\d* invalid/, output) do
      names
    else
      headers = Regex.scan(@failure_header, output, capture: :all_but_first)
      failing = Enum.map(headers, &hd/1)
      Enum.filter(names, fn name -> Enum.any?(failing, &failed_name?(&1, name)) end)
    end
  end

  @doc "Repair feedback: the failing edge tests and their ExUnit failure output."
  @spec findings([String.t()], String.t()) :: String.t()
  def findings(failing, output) do
    String.trim("""
    Kogen ran black-box edge tests, written from the Request alone, against this Candidate. Its own checks are green, but these edge tests failed:
    #{Enum.map_join(failing, "\n", &"- #{&1}")}

    ExUnit failure output:
    #{failure_output(output)}

    These tests were not shown to you and may be wrong. Change the implementation only where the Request requires the tested behaviour, keep every existing check green, and do not add these tests to the project.
    """)
  end

  defp failed_name?(failing, name), do: failing == name or String.ends_with?(failing, " " <> name)

  defp failure_output(output) do
    excerpt =
      case :binary.match(output, "1) test ") do
        {start, _length} -> binary_part(output, start, byte_size(output) - start)
        :nomatch -> output
      end

    if byte_size(excerpt) > @failure_limit,
      do: binary_part(excerpt, 0, @failure_limit) <> "\n[truncated]",
      else: excerpt
  end

  defp fenced(text) do
    case Regex.run(~r/```(?:elixir|exs|ex)?[ \t]*\n(.*?)```/s, text, capture: :all_but_first) do
      [source] -> source
      nil -> text
    end
  end

  defp tag_extra(lines) do
    {lines, names} =
      Enum.reduce(lines, {[], []}, fn line, {lines, names} ->
        case Regex.run(@test_line, line) do
          [_match, indent, _name] when length(names) >= @max_tests ->
            {[line, "#{indent}@tag :#{@extra_tag}" | lines], names}

          [_match, _indent, name] ->
            {[line | lines], [name | names]}

          nil ->
            {[line | lines], names}
        end
      end)

    {Enum.reverse(lines), Enum.reverse(names)}
  end
end
