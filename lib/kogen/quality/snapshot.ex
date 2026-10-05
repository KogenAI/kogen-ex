defmodule Kogen.Quality.Snapshot do
  @moduledoc false
  alias Kogen.Quality.Process, as: Command

  @spec create(struct(), [Path.t()]) :: {:ok, Path.t()} | {:error, term()}
  def create(request, paths) do
    directory =
      Path.join(request.run_dir, "quality-#{System.pid()}-#{System.unique_integer([:positive])}")

    with {:ok, _} <-
           Command.run(
             request,
             [
               "git",
               "clone",
               "--shared",
               "--quiet",
               "--no-checkout",
               "--",
               request.workdir,
               directory
             ],
             request.workdir
           ),
         {:ok, _} <-
           Command.run(
             request,
             ["git", "checkout", "--quiet", "--detach", request.base],
             directory
           ),
         :ok <- tool_cache(request, directory),
         :ok <- copy_candidate(request.workdir, directory, paths),
         {:ok, _} <- Command.run(request, ["git", "add", "--all"], directory),
         {:ok, _} <- Command.run(request, commit_args(), directory) do
      {:ok, directory}
    end
  end

  defp commit_args do
    [
      "git",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "user.name=Kogen Quality",
      "-c",
      "user.email=quality@kogen.invalid",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "--quiet",
      "--allow-empty",
      "-m",
      "Quality snapshot"
    ]
  end

  defp tool_cache(request, directory) do
    Enum.reduce_while(["deps", "_build/" <> request.mix_env], :ok, fn name, :ok ->
      source = Path.join(request.workdir, name)

      File.mkdir_p!(Path.dirname(Path.join(directory, name)))

      if File.dir?(source) do
        case Command.run(request, copy_args(source, Path.join(directory, name)), request.workdir) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp copy_args(source, destination) do
    case :os.type() do
      {:unix, :darwin} -> ["cp", "-cR", source, destination]
      _other -> ["cp", "-R", source, destination]
    end
  end

  defp copy_candidate(source, destination, paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      target = Path.join(destination, path)

      case File.read(Path.join(source, path)) do
        {:ok, bytes} ->
          with :ok <- File.mkdir_p(Path.dirname(target)), :ok <- File.write(target, bytes) do
            {:cont, :ok}
          else
            {:error, _} = error -> {:halt, error}
          end

        {:error, :enoent} ->
          File.rm(target)
          {:cont, :ok}

        error ->
          {:halt, error}
      end
    end)
  end
end
