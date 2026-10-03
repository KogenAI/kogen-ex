defmodule Kogen.Checks.ShapeFormatter do
  @moduledoc false

  alias Kogen.Checks.ShapeFormatRequest
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project
  alias Kogen.Proc

  @format_timeout_ms 120_000

  @spec format_files(ShapeFormatRequest.t()) ::
          :ok | {:warning, Failure.t()} | {:error, Failure.t()}
  def format_files(%ShapeFormatRequest{} = request) do
    expected_paths = [intent_path(request.slug), acceptance_path(request.slug)]

    files =
      request.written_paths
      |> Enum.filter(&(&1 in expected_paths and source_file?(&1)))
      |> Enum.filter(&File.regular?(Path.join(request.workdir, &1)))

    case files do
      [] ->
        :ok

      _files ->
        run_formatter(request, files)
    end
  end

  defp run_formatter(%ShapeFormatRequest{} = request, files) do
    with :ok <- prepare_logs(request.run_dir) do
      log_path = Path.join([request.run_dir, "logs", "shape-format.log"])
      formatter = formatter_argv(request.project)
      argv = formatter ++ files

      case Proc.run(argv,
             cd: request.workdir,
             env: request.env,
             timeout_ms: @format_timeout_ms,
             log_path: log_path,
             sandbox: request.sandbox
           ) do
        {:ok, %ProcResult{exit_status: 0, timed_out: false}} ->
          :ok

        {:ok, %ProcResult{exit_status: 127, timed_out: false}} ->
          missing_formatter(argv, files, log_path)

        {:ok, %ProcResult{} = result} ->
          {:error, formatter_failure(argv, files, result, log_path)}

        {:error, :enoent} ->
          missing_formatter(argv, files, log_path)

        {:error, reason} ->
          {:error,
           failure(:environment, :format_failed, "formatter could not run: #{inspect(reason)}")}
      end
    end
  end

  defp formatter_argv(%Project{format: format}) when is_list(format), do: format

  defp formatter_argv(%Project{checks: checks}) do
    case Enum.find(checks, fn check ->
           "format" in check.argv and "--check-formatted" in check.argv
         end) do
      %{argv: argv} -> Enum.reject(argv, &(&1 == "--check-formatted"))
      nil -> ["mix", "format"]
    end
  end

  defp missing_formatter(argv, files, log_path) do
    failure =
      failure(
        :environment,
        :tool_missing,
        "Controller formatter #{Enum.join(argv, " ")} is unavailable for #{Enum.join(files, " ")}."
      )

    warning =
      "WARNING: #{failure.class}/#{failure.reason}: #{failure.detail} Skipping controller formatting; project checks will still run.\n"

    case File.write(log_path, warning, [:append]) do
      :ok ->
        {:warning, failure}

      {:error, reason} ->
        {:error,
         failure(
           :environment,
           :format_warning_log_failed,
           "Could not record formatter warning: #{inspect(reason)}"
         )}
    end
  end

  defp formatter_failure(argv, files, %ProcResult{} = result, log_path) do
    status = if result.timed_out, do: "timed out", else: "exited #{inspect(result.exit_status)}"

    failure(
      :candidate,
      :format_failed,
      "#{Enum.join(argv, " ")} #{status} while formatting #{Enum.join(files, " ")}.\n" <>
        "Output (first 20 lines):\n" <> first_output_lines(log_path, result.output_tail)
    )
  end

  defp first_output_lines(path, fallback) do
    output =
      case File.read(path) do
        {:ok, contents} -> contents
        {:error, _reason} -> fallback
      end

    output |> String.split("\n", trim: false) |> Enum.take(20) |> Enum.join("\n")
  end

  defp prepare_logs(run_dir) do
    case File.mkdir_p(Path.join(run_dir, "logs")) do
      :ok -> :ok
      {:error, reason} -> {:error, failure(:environment, :log_directory_failed, inspect(reason))}
    end
  end

  defp source_file?(path), do: Path.extname(path) in [".ex", ".exs"]

  defp intent_path(slug), do: ".kogen/intents/#{slug}/intent.md"
  defp acceptance_path(slug), do: ".kogen/acceptance/#{slug}_test.exs"

  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
