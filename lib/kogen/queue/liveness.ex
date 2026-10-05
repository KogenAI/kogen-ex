defmodule Kogen.Queue.Liveness do
  @moduledoc "Checks whether an OS process is alive, without signalling it."

  alias Kogen.Proc

  @pid_liveness_script """
  use Errno qw(ESRCH EPERM);
  my $pid = shift @ARGV;
  local $! = 0;
  my $found = kill(0, $pid);
  exit 0 if $found;
  exit 1 if $! == ESRCH;
  exit 0 if $! == EPERM;
  exit 2;
  """

  @spec alive?(integer() | nil, Path.t()) :: {:ok, boolean()} | {:error, term()}
  def alive?(pid, directory) when is_integer(pid) and pid > 0 do
    case Proc.run(
           ["/usr/bin/perl", "-e", @pid_liveness_script, Integer.to_string(pid)],
           cd: directory
         ) do
      {:ok, %{exit_status: 0}} ->
        {:ok, true}

      {:ok, %{exit_status: 1}} ->
        {:ok, false}

      {:ok, %{exit_status: status, output_tail: output}} ->
        {:error, {:owner_liveness_check_failed, status, output}}

      {:error, reason} ->
        {:error, {:owner_liveness_check_failed, reason}}
    end
  end

  def alive?(_pid, _directory), do: {:ok, false}
end
