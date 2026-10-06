defmodule Kogen.Quality.Analysis do
  @moduledoc false
  alias Kogen.Quality.Baseline
  alias Kogen.Quality.Clones
  alias Kogen.Quality.Process, as: Command
  alias Kogen.Quality.Reach
  alias Kogen.Quality.Report
  alias Kogen.Quality.Suppressions
  alias Kogen.Workspace

  @spec run(struct()) :: [map()]
  def run(request) do
    if File.regular?(Path.join(request.workdir, "mix.exs")) do
      analyze(request)
    else
      []
    end
  end

  defp analyze(request) do
    with :ok <- File.mkdir_p(Path.join(request.run_dir, "logs")),
         {:ok, revision} <-
           Command.run(
             request,
             ["git", "rev-parse", "--verify", request.base <> "^{commit}"],
             request.workdir
           ),
         request = %{request | base: String.trim(revision)},
         {:ok, paths} <- Workspace.changed_paths(request.workdir, request.base, request.env),
         {:ok, dependencies} <- dependencies(request.workdir),
         {:ok, request} <- Baseline.extract(request) do
      sources = Enum.filter(paths, &(Path.extname(&1) in [".ex", ".exs"]))

      [
        Suppressions.run(request, sources),
        Kogen.Quality.Mutation.run(request, paths),
        optional(:ex_dna, dependencies, fn -> Clones.run(request, sources) end),
        optional(:reach, dependencies, fn -> Reach.run(request, paths) end)
      ]
    else
      {:error, _} -> [Report.skip("quality", "Build diff unavailable")]
    end
  end

  defp optional(tool, dependencies, run) do
    if tool in dependencies,
      do: run.(),
      else: Report.skip(to_string(tool), "dependency missing from mix.exs")
  end

  defp dependencies(root) do
    with {:ok, source} <- File.read(Path.join(root, "mix.exs")),
         {:ok, ast} <- Code.string_to_quoted(source) do
      {_, found} =
        Macro.prewalk(ast, [], fn
          {name, _version} = node, acc when name in [:ex_dna, :reach] ->
            {node, [name | acc]}

          {:{}, _, [name | _]} = node, acc when name in [:ex_dna, :reach] ->
            {node, [name | acc]}

          node, acc ->
            {node, acc}
        end)

      {:ok, found}
    end
  end
end
