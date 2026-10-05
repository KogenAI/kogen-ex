defmodule Kogen.Quality.Process do
  @moduledoc false
  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Quality.Request

  @spec run(Request.t(), [String.t()], Path.t()) :: {:ok, binary()} | {:error, atom()}
  def run(request, argv, directory) do
    remaining = request.deadline - System.monotonic_time(:millisecond)

    log =
      Path.join([request.run_dir, "logs", "quality-#{System.unique_integer([:positive])}.log"])

    if remaining > 0 do
      execute(request, argv, directory, remaining, log)
    else
      {:error, :budget_exhausted}
    end
  end

  defp execute(request, argv, directory, remaining, log) do
    case Proc.run(argv,
           cd: directory,
           env: request.env,
           timeout_ms: remaining,
           log_path: log,
           sandbox: request.sandbox
         ) do
      {:ok, %ProcResult{exit_status: 0, timed_out: false}} -> File.read(log)
      {:ok, %ProcResult{timed_out: true}} -> {:error, :budget_exhausted}
      _unavailable -> {:error, :tool_unavailable}
    end
  end

  @spec json(Request.t(), [String.t()], Path.t()) :: {:ok, map()} | {:error, atom()}
  def json(request, argv, directory) do
    with {:ok, output} <- run(request, argv, directory) do
      decode(output)
    end
  end

  defp decode(output) do
    # Mix may print dependency compilation before the JSON document.
    candidates = Regex.scan(~r/(?:\A|\n)(\{)/, output, return: :index)

    Enum.find_value(candidates, {:error, :invalid_report}, fn [_, {offset, _}] ->
      case JSON.decode(binary_part(output, offset, byte_size(output) - offset)) do
        {:ok, value} when is_map(value) -> {:ok, value}
        _invalid -> nil
      end
    end)
  end
end
