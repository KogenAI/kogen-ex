defmodule Kogen.Quality.Suppressions do
  @moduledoc false
  alias Kogen.Quality.Report

  @marker "# " <> "reach:" <> "disable"

  @spec run(struct(), [Path.t()]) :: map()
  def run(request, paths) do
    findings = Enum.flat_map(paths, &added(request, &1))
    Report.command("reach_suppressions", findings)
  end

  defp added(request, path) do
    old =
      case File.read(Path.join(request.baseline, path)) do
        {:ok, source} -> comments(source)
        _absent -> []
      end

    new =
      case File.read(Path.join(request.workdir, path)) do
        {:ok, source} -> comments(source)
        _absent -> []
      end

    {added, _} = Enum.reduce(new, {[], Enum.frequencies_by(old, &elem(&1, 0))}, &delta/2)

    for {text, line} <- added, not Regex.match?(~r/\s+--\s*\S/, text) do
      Report.finding(
        "reach",
        "reasonless_suppression",
        path,
        line,
        "Add a reason on the same line using -- reason, or remove the Reach suppression.",
        :error
      )
    end
  end

  defp comments(source) do
    case Code.string_to_quoted_with_comments(source) do
      {:ok, _, comments} ->
        for %{text: text, line: line} <- comments,
            String.starts_with?(text, @marker),
            do: {String.trim(text), line}

      _invalid ->
        []
    end
  end

  defp delta({text, _line} = item, {added, counts}) do
    case Map.get(counts, text, 0) do
      0 -> {[item | added], counts}
      count -> {added, Map.put(counts, text, count - 1)}
    end
  end
end
