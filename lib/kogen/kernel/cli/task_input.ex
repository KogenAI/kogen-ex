defmodule Kogen.Kernel.CLI.TaskInput do
  @moduledoc false

  @spec read(Path.t() | nil, term()) :: {:ok, binary()} | {:error, term()}
  def read(path, stdin \\ :stdio)

  def read(path, stdin) when is_nil(path) or path == "-" do
    case IO.read(stdin, :eof) do
      task when is_binary(task) -> nonempty(task, "stdin")
      {:error, reason} -> {:error, {:task_input_unavailable, "stdin", reason}}
      :eof -> {:error, {:task_input_unavailable, "stdin", :empty}}
    end
  end

  def read(path, _stdin) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, task} -> nonempty(task, expanded)
      {:error, reason} -> {:error, {:task_input_unavailable, expanded, reason}}
    end
  end

  defp nonempty(task, source) do
    if String.trim(task) == "",
      do: {:error, {:task_input_unavailable, source, :empty}},
      else: {:ok, task}
  end
end
