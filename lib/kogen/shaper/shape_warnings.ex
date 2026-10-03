defmodule Kogen.Shaper.ShapeWarnings do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ShapeWarning
  alias Kogen.Contracts.ShapeWarningCodec
  alias Kogen.Intent

  @spec clear(Path.t(), String.t()) :: :ok | {:error, Failure.t()}
  def clear(workdir, slug) do
    case File.rm(warnings_path(workdir, slug)) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error,
         failure(
           :shape_warning_clear_failed,
           "Could not clear prior shape warnings: #{inspect(reason)}"
         )}
    end
  end

  @spec write(Path.t(), String.t(), [ShapeWarning.t()]) :: :ok | {:error, Failure.t()}
  def write(workdir, slug, []) do
    clear(workdir, slug)
  end

  def write(workdir, slug, warnings) do
    intent_path = Path.join([workdir, ".kogen", "intents", slug, "intent.md"])

    with {:ok, bytes} <- File.read(intent_path),
         encoded = ShapeWarningCodec.encode(Intent.hash(bytes), warnings),
         :ok <- File.write(warnings_path(workdir, slug), encoded) do
      :ok
    else
      {:error, reason} ->
        {:error,
         failure(:shape_warning_write_failed, "Could not save shape warnings: #{inspect(reason)}")}
    end
  end

  defp warnings_path(workdir, slug),
    do: Path.join([workdir, ".kogen", "intents", slug, "shape-warnings.json"])

  defp failure(reason, detail), do: %Failure{class: :environment, reason: reason, detail: detail}
end
