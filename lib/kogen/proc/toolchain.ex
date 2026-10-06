defmodule Kogen.Proc.Toolchain do
  @moduledoc false

  alias Kogen.Contracts.JSON
  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc

  @output_tail_bytes 2_048

  @spec environment(Path.t(), Path.t(), map()) ::
          {:ok, %{String.t() => String.t()}}
          | {:error, :invalid_toolchain_environment | {:toolchain_failed, String.t()}}
  def environment(workdir, mise, env) do
    case Proc.run(
           [mise, "env", "-C", workdir, "--json", "--quiet"],
           cd: workdir,
           env: env,
           timeout_ms: 30_000
         ) do
      {:ok, %ProcResult{exit_status: 0, timed_out: false, output_tail: output}} ->
        decode_environment(output)

      {:ok, %ProcResult{output_tail: output}} ->
        {:error, {:toolchain_failed, toolchain_failure_detail(output)}}

      {:error, reason} ->
        {:error, {:toolchain_failed, "mise env failed: #{inspect(reason)}"}}
    end
  end

  defp toolchain_failure_detail(output) do
    offset = max(byte_size(output) - @output_tail_bytes, 0)
    output = output |> binary_part(offset, byte_size(output) - offset) |> String.replace_invalid()
    if output == "", do: "mise env failed", else: "mise env failed:\n" <> output
  end

  defp decode_environment(output) do
    case JSON.decode(output) do
      {:ok, values} when is_map(values) ->
        string_environment(values)

      _other ->
        {:error, :invalid_toolchain_environment}
    end
  end

  defp string_environment(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, env} ->
      if is_binary(key) and is_binary(value) do
        {:cont, {:ok, Map.put(env, key, value)}}
      else
        {:halt, {:error, :invalid_toolchain_environment}}
      end
    end)
  end
end
