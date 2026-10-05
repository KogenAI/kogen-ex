defmodule Mix.Tasks.Kogen.Guard do
  @shortdoc "Checks repository guard rules"
  @moduledoc "Runs repository-wide checks for disabled or bypassed quality gates."
  use Mix.Task
  use Boundary, classify_to: Kogen.Mix

  @ignored_directories [".git", "_build", "deps"]
  @forbidden_names ["AGENTS" <> ".md", "CLAUDE" <> ".md"]
  @source_markers [
    ["credo:", "disable"],
    ["@", "dialyzer"],
    ["@compile ", "{:nowarn"],
    ["exports:", " :all"],
    ["dirty_", "xrefs"],
    ["check:", " [in: false"],
    ["check:", " [out: false"]
  ]
  @make_marker ["|", "|", " true"]

  @impl Mix.Task
  def run(_args) do
    root = Path.dirname(Mix.Project.project_file())

    case violations(root) do
      [] ->
        Mix.shell().info("guard OK")

      issues ->
        Mix.raise("guard failed:\n" <> Enum.join(issues, "\n"))
    end
  end

  @spec violations(Path.t()) :: [String.t()]
  def violations(root) do
    root = Path.expand(root)
    files = project_files(root)

    name_issues = Enum.flat_map(files, &name_issues(&1, root))
    script_issues = Enum.flat_map(files, &script_issues(&1, root))
    source_issues = Enum.flat_map(files, &source_issues(&1, root))
    make_issues = make_issues(root)
    reach_issues = Enum.flat_map(files, &reach_issues(&1, root))

    name_issues ++ script_issues ++ source_issues ++ make_issues ++ reach_issues
  end

  defp project_files(root), do: walk(root)

  defp walk(directory) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = Path.join(directory, name)
      stat = File.lstat!(path)

      case stat.type do
        :directory when name in @ignored_directories -> []
        :directory -> walk(path)
        type when type in [:regular, :symlink] -> [path]
        _ -> []
      end
    end)
  end

  defp name_issues(path, root) do
    if Path.basename(path) in @forbidden_names do
      [issue(path, root, 1, "instruction files are not allowed")]
    else
      []
    end
  end

  defp script_issues(path, root) do
    if Path.extname(path) == ".sh" do
      [issue(path, root, 1, "shell scripts are not allowed")]
    else
      []
    end
  end

  defp source_issues(path, root) do
    if source_path?(path, root) and regular_file?(path) do
      markers = Enum.map(@source_markers, &Enum.join/1)
      marker_issues(path, root, markers, "forbidden source marker")
    else
      []
    end
  end

  defp reach_issues(path, root) do
    if source_path?(path, root) and regular_file?(path) do
      marker = "# " <> "reach:" <> "disable"

      case Code.string_to_quoted_with_comments(File.read!(path)) do
        {:ok, _, comments} ->
          for %{text: text, line: line} <- comments,
              String.starts_with?(text, marker),
              not Regex.match?(~r/\s+--\s*\S/, text),
              do: issue(path, root, line, "Reach suppression needs a reason on the same line")

        _invalid ->
          []
      end
    else
      []
    end
  end

  defp make_issues(root) do
    path = Path.join(root, "Makefile")

    if regular_file?(path) do
      marker_issues(
        path,
        root,
        [Enum.join(@make_marker)],
        "Makefile error suppression is not allowed"
      )
    else
      []
    end
  end

  defp marker_issues(path, root, markers, message) do
    path
    |> File.read!()
    |> :binary.split("\n", [:global])
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      for marker <- markers, :binary.match(line, marker) != :nomatch do
        issue(path, root, number, "#{message}: #{marker}")
      end
    end)
  end

  defp source_path?(path, root) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> List.first()
    |> Kernel.in(["lib", "test"])
  end

  defp regular_file?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> true
      _ -> false
    end
  end

  defp issue(path, root, line, message) do
    "#{Path.relative_to(path, root)}:#{line}: #{message}"
  end
end
