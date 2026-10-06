defmodule Kogen.Quality.TestReach do
  @moduledoc false
  @module_reference ~r/\b[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\b/
  @environment_paths ["mix.exs", "mix.lock", ".mise.toml", ".kogen/project.yaml"]

  @spec reached?(map(), String.t(), [String.t()] | :unknown) :: boolean()
  def reached?(_opts, _test_id, :unknown), do: true

  def reached?(opts, test_id, changed_paths) do
    case test_path(test_id, opts.workdir) do
      {:ok, test_path} ->
        case File.read(Path.join(opts.workdir, test_path)) do
          {:ok, source} ->
            module_paths = referenced_module_paths(source)

            Enum.any?(changed_paths, fn path ->
              path == test_path or
                path in module_paths or
                environment_path?(path) or
                test_support_path?(path)
            end)

          {:error, _reason} ->
            true
        end

      :error ->
        true
    end
  end

  # Reach is a direct-source heuristic: a changed test file, test support/config file, or
  # `lib/<Macro.underscore(Module.Name)>.ex` named in the test source counts as touched.
  # If the test source or changed-path list cannot be read, the result fails closed as reached.
  defp referenced_module_paths(source) do
    @module_reference
    |> Regex.scan(source)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.map(&Macro.underscore/1)
    |> Enum.map(&"lib/#{&1}.ex")
  end

  defp environment_path?(path),
    do: path in @environment_paths or String.starts_with?(path, "config/")

  defp test_support_path?(path), do: String.starts_with?(path, "test/")

  defp test_path(test_id, workdir) do
    case String.split(test_id, ":", parts: 2) do
      [path, _line] ->
        expanded = Path.expand(path, workdir)
        relative = Path.relative_to(expanded, Path.expand(workdir))

        if ".." in Path.split(relative) or Path.type(relative) == :absolute,
          do: :error,
          else: {:ok, relative}

      _other ->
        :error
    end
  end
end
