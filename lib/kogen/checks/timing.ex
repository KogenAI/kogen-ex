defmodule Kogen.Checks.Timing do
  @moduledoc "Records advisory timing evidence for verification and shaping gates."

  alias Kogen.Contracts.GateTiming
  alias Kogen.Contracts.GateTiming.Codec
  alias Kogen.Contracts.JSON
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.ShapeWarning

  @spec finish(tuple(), integer(), Path.t()) :: tuple()
  def finish({:ok, result}, started, run_dir) do
    timing = GateTiming.summarize(result.checks, elapsed(started))
    record(run_dir, timing)
    {:ok, Map.merge(result, %{timing: timing, warnings: result.warnings ++ timing.warnings})}
  end

  def finish(error, _started, _run_dir), do: error

  @spec process(tuple(), Path.t(), String.t(), [String.t()]) :: tuple()
  def process({:ok, %ProcResult{} = result} = original, run_dir, name, argv) do
    record(
      run_dir,
      GateTiming.summarize(
        [%{name: name, argv: argv, duration_ms: result.duration_ms}],
        result.duration_ms
      )
    )

    original
  end

  def process(error, _run_dir, _name, _argv), do: error

  @spec record(Path.t(), GateTiming.t()) :: :ok
  def record(run_dir, timing) do
    Enum.each(timing.warnings, &IO.puts(:stderr, &1))

    case File.mkdir_p(run_dir) do
      :ok ->
        case File.write(path(run_dir), [encode(timing), "\n"], [:append]) do
          :ok ->
            :ok

          {:error, reason} ->
            IO.puts(:stderr, "Gate timing evidence could not be saved: #{inspect(reason)}")
        end

      {:error, reason} ->
        IO.puts(:stderr, "Gate timing directory unavailable: #{inspect(reason)}")
    end

    :ok
  end

  @spec shape(Path.t(), (-> tuple())) :: tuple()
  def shape(run_dir, operation) do
    before = length(read(run_dir))
    started = System.monotonic_time(:millisecond)
    result = operation.()
    stages = run_dir |> read() |> Enum.drop(before) |> Enum.map(&stage/1)
    timing = GateTiming.summarize(stages, elapsed(started))
    record(run_dir, timing)

    case result do
      {:ok, warnings} ->
        {:ok,
         warnings ++
           Enum.map(
             timing.warnings,
             &%ShapeWarning{code: :gate_time_budget, item_ids: [], message: &1}
           )}

      error ->
        error
    end
  end

  @spec complete(Path.t()) :: GateTiming.t()
  def complete(run_dir) do
    timing = GateTiming.combine(read(run_dir))
    record(run_dir, timing)
    timing
  end

  @spec latest(Path.t()) :: GateTiming.t() | nil
  def latest(run_dir), do: run_dir |> read() |> List.last()

  defp stage(timing) do
    %{
      name: (timing.slowest_stage && timing.slowest_stage.name) || "gate",
      argv: if(timing.test_duration_ms > 0, do: ["test"], else: []),
      duration_ms: timing.duration_ms
    }
  end

  defp read(run_dir) do
    if File.exists?(path(run_dir)), do: read_file(path(run_dir)), else: []
  end

  defp read_file(file) do
    case File.read(file) do
      {:ok, bytes} ->
        bytes
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case JSON.decode(line) do
            {:ok, record} when is_map(record) -> [Codec.decode(record)]
            _invalid -> []
          end
        end)

      {:error, reason} ->
        :logger.warning("Gate timing evidence unavailable: #{inspect(reason)}")
        []
    end
  end

  defp encode(timing), do: timing |> Map.from_struct() |> :json.encode() |> IO.iodata_to_binary()
  defp path(run_dir), do: Path.join(run_dir, "gate-timings.jsonl")
  defp elapsed(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
