defmodule Kogen.Runner.ScratchTests do
  @moduledoc false

  # Runs extra test files against a Candidate in a scratch copy of its checkout, with the
  # gate's `mix test` command and a fixed seed. Shared by the parallel cross-check and the
  # edge probe.

  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Stack
  alias Kogen.Engine.Build.GateSupport
  alias Kogen.Engine.Build.Session

  @summary ~r/(\d+) tests?, (\d+) failures?/
  @result ~r/Result: (\d+)(?:\/(\d+))? passed/

  @doc "The project's gate check that runs `mix test`."
  @spec test_command(Session.t()) :: {:ok, map()} | {:error, :no_test_command}
  def test_command(%Session{project: %{checks: checks}}) do
    case Enum.find(checks, &(Stack.test_command_index(&1.argv) != nil)) do
      nil -> {:error, :no_test_command}
      spec -> {:ok, spec}
    end
  end

  @doc """
  Runs `paths` from `files` in a scratch copy of `member`'s checkout with the gate's test
  command limited to them; `extra` arguments are appended and `name` labels the scratch copy.
  """
  @spec run(Session.t(), map(), %{String.t() => binary()}, [String.t()], keyword()) ::
          {:ok, ProcResult.t()} | {:error, term()}
  def run(%Session{} = member, spec, files, paths, options) do
    argv = argv(spec.argv, Enum.sort(paths), Keyword.get(options, :extra, []))
    timeout_ms = Keyword.fetch!(options, :timeout_ms)

    GateSupport.scratch_test(
      member,
      files,
      argv,
      timeout_ms,
      Keyword.get(options, :name, "cross-check")
    )
  end

  @doc "The test count and passed count from ExUnit output, or nil without a summary."
  @spec summary(binary()) :: {non_neg_integer(), non_neg_integer()} | nil
  def summary(output) do
    case {Regex.scan(@result, output), Regex.scan(@summary, output)} do
      {[_ | _] = matches, _summary} ->
        case List.last(matches) do
          [_line, passed] -> {String.to_integer(passed), String.to_integer(passed)}
          [_line, passed, tests] -> {String.to_integer(tests), String.to_integer(passed)}
        end

      {[], [_ | _] = matches} ->
        [_line, tests, failures] = List.last(matches)
        tests = String.to_integer(tests)
        {tests, max(tests - String.to_integer(failures), 0)}

      {[], []} ->
        ruby_summary(output)
    end
  end

  defp ruby_summary(output) do
    case Regex.scan(
           ~r/(\d+) runs, \d+ assertions, (\d+) failures, (\d+) errors, (\d+) skips/,
           output
         ) do
      [] ->
        nil

      matches ->
        [_line | counts] = List.last(matches)
        [tests, failures, errors, skips] = Enum.map(counts, &String.to_integer/1)
        {tests, max(tests - failures - errors - skips, 0)}
    end
  end

  @spec test_file?(String.t()) :: boolean()
  def test_file?(path), do: String.ends_with?(path, ["_test.exs", "_test.rb"])

  @doc "How many warnings the member's last gate reported."
  @spec warnings(Session.t()) :: non_neg_integer()
  def warnings(%Session{last_harness: %{gate: %{warnings: warnings}}}) when is_list(warnings),
    do: length(warnings)

  def warnings(_member), do: 0

  @spec label(term()) :: String.t()
  def label(:builder), do: "builder"
  def label(attempt), do: to_string(attempt)

  # The gate's test command limited to the given files, with a fixed seed.
  defp argv(argv, files, extra) do
    {command, args} = Enum.split(argv, Stack.test_command_index(argv) + 2)
    command ++ files ++ drop_selectors(args) ++ extra ++ ["--seed", "0"]
  end

  defp drop_selectors(["--seed", _value | rest]), do: drop_selectors(rest)
  defp drop_selectors(["--seed=" <> _value | rest]), do: drop_selectors(rest)

  defp drop_selectors([arg | rest]) do
    if String.ends_with?(arg, [".exs", ".rb"]) or Regex.match?(~r/\.(?:exs|rb):\d+\z/, arg),
      do: drop_selectors(rest),
      else: [arg | drop_selectors(rest)]
  end

  defp drop_selectors([]), do: []
end
