defmodule Kogen.Quality.Baseline do
  @moduledoc false
  alias Kogen.Quality.Process, as: Command

  @spec extract(struct()) :: {:ok, struct()} | {:error, term()}
  def extract(request) do
    directory = Path.join(request.run_dir, "quality-base-#{System.unique_integer([:positive])}")
    archive = directory <> ".tar"

    with :ok <- File.mkdir_p(directory),
         {:ok, _} <-
           Command.run(
             request,
             ["git", "archive", "--format=tar", "--output=" <> archive, request.base],
             request.workdir
           ),
         {:ok, _} <-
           Command.run(request, ["tar", "-xf", archive, "-C", directory], request.workdir) do
      File.rm(archive)
      {:ok, %{request | baseline: directory}}
    end
  end
end
