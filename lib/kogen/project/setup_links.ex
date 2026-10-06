defmodule Kogen.Project.SetupLinks do
  @moduledoc false

  @spec rebase(Path.t(), Path.t(), Path.t(), Path.t()) :: :ok | {:error, term()}
  def rebase(source_root, target_root, relative, link_root) do
    destination = Path.join(target_root, relative)

    case File.lstat(destination) do
      {:ok, %{type: :directory}} ->
        children(source_root, target_root, relative, link_root)

      {:ok, %{type: :symlink}} ->
        link(source_root, target_root, relative, link_root)

      {:ok, %{type: :regular}} ->
        :ok

      other ->
        {:error, {:unsafe_setup_output, relative, other}}
    end
  end

  defp children(source_root, target_root, relative, link_root) do
    with {:ok, names} <- File.ls(Path.join(target_root, relative)) do
      Enum.reduce_while(names, :ok, fn child, :ok ->
        case rebase(source_root, target_root, Path.join(relative, child), link_root) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp link(source_root, target_root, relative, link_root) do
    destination = Path.join(target_root, relative)

    with {:ok, target} <- File.read_link(destination) do
      absolute = Path.expand(target, Path.dirname(Path.join(source_root, relative)))

      if String.starts_with?(absolute, source_root <> "/") do
        relocated = Path.join(link_root, Path.relative_to(absolute, source_root))
        with :ok <- File.rm(destination), do: File.ln_s(relocated, destination)
      else
        {:error, {:setup_output_link_outside_workspace, relative}}
      end
    end
  end
end
