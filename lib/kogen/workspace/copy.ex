defmodule Kogen.Workspace.Copy do
  @moduledoc false

  alias Kogen.Contracts.ProcResult
  alias Kogen.Workspace.Process

  @timeout_ms 900_000

  @spec copy_on_write(Path.t(), Path.t()) :: :ok | {:error, term()}
  def copy_on_write(source, destination) do
    with :ok <- File.mkdir_p(Path.dirname(destination)) do
      case run(copy_args(source, destination), Path.dirname(destination)) do
        :ok -> :ok
        {:error, _reason} -> plain_copy(source, destination)
      end
    end
  end

  defp copy_args(source, destination) do
    case :os.type() do
      {:unix, :darwin} -> ["cp", "-cR", source, destination]
      {:unix, :linux} -> ["cp", "--reflink=auto", "-R", source, destination]
      _other -> ["cp", "-R", source, destination]
    end
  end

  defp plain_copy(source, destination) do
    _cleanup = File.rm_rf(destination)

    case run(["cp", "-R", source, destination], Path.dirname(destination)) do
      :ok -> :ok
      {:error, _reason} -> file_copy(source, destination)
    end
  end

  defp file_copy(source, destination) do
    _cleanup = File.rm_rf(destination)

    case File.cp_r(source, destination) do
      {:ok, _copied} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp run(argv, directory) do
    case Process.run(argv, cd: directory, timeout_ms: @timeout_ms) do
      {:ok, %ProcResult{exit_status: 0, timed_out: false}} -> :ok
      _failure -> {:error, :copy_failed}
    end
  end
end
