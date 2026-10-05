defmodule Kogen.Quality.Clones do
  @moduledoc false
  alias Kogen.Quality.Codec
  alias Kogen.Quality.Process, as: Command
  alias Kogen.Quality.Report

  @spec run(struct(), [Path.t()]) :: map()
  def run(request, paths) do
    paths = Enum.filter(paths, &handwritten?(request.workdir, &1))

    if paths == [] do
      Report.command("ex_dna", [])
    else
      compare(request, paths)
    end
  end

  defp compare(request, paths) do
    baseline = request.baseline

    old_paths =
      paths |> Enum.filter(&handwritten?(baseline, &1)) |> Enum.map(&Path.join(baseline, &1))

    with {:ok, old} <- analyze(request, old_paths),
         {:ok, new} <- analyze(request, Enum.map(paths, &Path.join(request.workdir, &1))) do
      before =
        Enum.frequencies_by(
          if(old == %{}, do: [], else: Codec.clones(old)),
          &identity(&1, baseline)
        )

      added = new_clones(Codec.clones(new), before, request.workdir)
      Report.command("ex_dna", Enum.map(added, &finding(&1, request.workdir)))
    else
      {:error, reason} -> Report.skip("ex_dna", reason)
    end
  end

  defp analyze(_request, []), do: {:ok, %{}}

  defp analyze(request, paths) do
    Command.json(
      request,
      ["mix", "ex_dna", "--format", "json", "--max-clones", "999999" | paths],
      request.workdir
    )
  end

  defp identity(clone, root) do
    snippets = clone.snippets |> Enum.map(&String.replace(&1, ~r/\s+/, " ")) |> Enum.sort()
    paths = clone.fragments |> Enum.map(&Path.relative_to(&1.file, root)) |> Enum.sort()
    {clone.type, snippets, paths}
  end

  defp new_clones(clones, counts, root) do
    {added, _} =
      Enum.reduce(clones, {[], counts}, fn clone, {added, counts} ->
        key = identity(clone, root)

        case Map.get(counts, key, 0) do
          0 -> {[clone | added], counts}
          count -> {added, Map.put(counts, key, count - 1)}
        end
      end)

    added
  end

  defp finding(clone, root) do
    locations =
      clone.fragments
      |> Enum.map(&{Path.relative_to(&1.file, root), &1.line})
      |> Enum.sort()

    [{path, line} | _] = locations
    both = Enum.map_join(locations, ", ", fn {path, line} -> "#{path}:#{line}" end)

    Report.finding(
      "ex_dna",
      "new_clone",
      path,
      line,
      "New clone at #{both}; extract the shared code."
    )
  end

  @spec handwritten?(Path.t(), Path.t()) :: boolean()
  def handwritten?(root, path) do
    if "generated" in Path.split(path) do
      false
    else
      case File.read(Path.join(root, path)) do
        {:ok, source} ->
          not Regex.match?(
            ~r/(?:^\s*#\s*(?:@generated|generated\b|.*automatically generated)|@generated\s+true)/im,
            source
          )

        {:error, :enoent} ->
          false

        {:error, _reason} ->
          true
      end
    end
  end
end
