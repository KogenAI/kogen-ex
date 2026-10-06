defmodule Kogen.Project.SetupKey do
  @moduledoc false

  alias Kogen.Contracts.Project

  @volatile_env ~w(MISE_STATE_DIR MISE_CACHE_DIR MISE_TRUSTED_CONFIG_PATHS)

  @spec build(Project.t(), Path.t(), String.t() | nil, map()) :: {:ok, String.t()} | :miss
  def build(project, workdir, base, env) do
    with true <- is_map(env),
         {:ok, inputs} <- inputs(project.setup_inputs, workdir, base) do
      key =
        digest({2, inputs, project.setup, project.setup_outputs, project.env, environment(env)})

      {:ok, key}
    else
      false -> :miss
      :miss -> :miss
    end
  end

  defp inputs(nil, _root, base) when is_binary(base) do
    if Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, base),
      do: {:ok, {:tree, base}},
      else: :miss
  end

  defp inputs(paths, root, _base) when is_list(paths) and paths != [] do
    paths
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, files} ->
      with true <- Kogen.Project.SetupInputs.safe?(path),
           true <- regular_path?(root, Path.split(path)),
           {:ok, stat} <- File.lstat(Path.join(root, path)),
           {:ok, bytes} <- File.read(Path.join(root, path)) do
        {:cont, {:ok, [{path, stat.mode, digest(bytes)} | files]}}
      else
        false -> {:halt, :miss}
        {:error, _reason} -> {:halt, :miss}
      end
    end)
  end

  defp inputs(_paths, _root, _base), do: :miss

  defp regular_path?(root, [file]),
    do: match?({:ok, %{type: :regular}}, File.lstat(Path.join(root, file)))

  defp regular_path?(root, [directory | rest]) do
    next = Path.join(root, directory)
    match?({:ok, %{type: :directory}}, File.lstat(next)) and regular_path?(next, rest)
  end

  defp environment(env) do
    {:os.type(), :erlang.system_info(:system_architecture), System.version(),
     System.otp_release(), Map.drop(env, @volatile_env)}
  end

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
