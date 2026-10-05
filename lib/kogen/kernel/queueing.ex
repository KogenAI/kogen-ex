defmodule Kogen.Kernel.Queueing do
  @moduledoc """
  Resolves a project's roots, origin and base once, then drives the queue domain: status
  with automatic crash recovery, Build reports, and starting, detaching and stopping the drain.
  """

  alias Kogen.Engine.Build.Result
  alias Kogen.Engine.Runtime
  alias Kogen.Kernel.ProjectContext
  alias Kogen.Kernel.RuntimeDiscovery
  alias Kogen.Kernel.Types.BuildOptions
  alias Kogen.Kernel.Types.QueueTarget
  alias Kogen.Kernel.Workspaces
  alias Kogen.Proc
  alias Kogen.Queue.BuildSummary
  alias Kogen.Queue.Drain
  alias Kogen.Queue.Lock
  alias Kogen.Queue.Recovery
  alias Kogen.Queue.StateView
  alias Kogen.Queue.Status

  # Forks, starts a new session so the caller's process-group cleanup can't reach the drain,
  # and reports the pid only once exec succeeded (the close-on-exec pipe then reads empty).
  @detach_script ~S"""
  use POSIX qw(setsid _exit);
  use Fcntl qw(F_SETFD FD_CLOEXEC);
  my $log = shift @ARGV;
  pipe(my $failed_r, my $failed_w) or die "pipe: $!";
  my $pid = fork();
  die "fork: $!" unless defined $pid;
  if ($pid) {
    close $failed_w;
    my $failure = do { local $/; <$failed_r> };
    if (defined $failure && length $failure) { print $failure; exit 1; }
    print "$pid\n";
    exit 0;
  }
  close $failed_r;
  fcntl($failed_w, F_SETFD, FD_CLOEXEC);
  sub fail { syswrite($failed_w, "$_[0]\n"); _exit(127); }
  setsid() or fail("setsid: $!");
  open(STDIN, '<', '/dev/null') or fail("stdin: $!");
  open(STDOUT, '>>', $log) or fail("log $log: $!");
  open(STDERR, '>&', \*STDOUT) or fail("stderr: $!");
  exec { $ARGV[0] } @ARGV;
  fail("exec $ARGV[0]: $!");
  """

  @spec status(Path.t(), Path.t() | nil, String.t() | nil) ::
          {:ok, [Kogen.Queue.IntentStatus.t()]} | {:error, term()}
  def status(project_root, origin, base) do
    with {:ok, target} <- resolve(project_root, origin, base),
         {:ok, _closed} <- recover(target) do
      statuses(target)
    end
  end

  @spec overview(Path.t(), Path.t() | nil, String.t() | nil) :: {:ok, map()} | {:error, term()}
  def overview(project_root, origin, base) do
    with {:ok, target} <- resolve(project_root, origin, base),
         {:ok, _closed} <- recover(target),
         {:ok, statuses} <- statuses(target) do
      case Lock.state(target.state_root) do
        {:error, reason} -> {:error, reason}
        queue -> {:ok, %{statuses: statuses, queue: queue}}
      end
    end
  end

  @spec report(String.t(), Path.t(), Path.t() | nil, String.t() | nil) ::
          {:ok, binary()} | {:error, term()}
  def report(slug, project_root, origin, base) do
    with {:ok, target} <- resolve(project_root, origin, base),
         {:ok, root} <-
           StateView.preferred_root(target.state_root, Path.join(project_root, ".kogen"), slug) do
      Kogen.Queue.Report.read(slug, root, target.origin, target.base, target.git_env)
    end
  end

  @spec build_summary(String.t(), Path.t(), Path.t() | nil, String.t() | nil) ::
          {:ok, BuildSummary.t() | nil} | {:error, term()}
  def build_summary(slug, project_root, origin, base) do
    with {:ok, target} <- resolve(project_root, origin, base),
         {:ok, root} <-
           StateView.preferred_root(target.state_root, Path.join(project_root, ".kogen"), slug) do
      BuildSummary.latest(root, slug)
    end
  end

  @spec reconcile(String.t(), Path.t(), Path.t() | nil, String.t() | nil) ::
          {:ok, :crashed | :landed | :unchanged} | {:error, term()}
  def reconcile(run_id, project_root, origin, base) do
    with {:ok, target} <- resolve(project_root, origin, base) do
      Recovery.run(
        run_id,
        project_root,
        target.state_root,
        target.origin,
        target.base,
        target.git_env
      )
    end
  end

  @spec start(Path.t(), Path.t() | nil, String.t() | nil, (String.t() -> :ok)) ::
          {:ok, Drain.summary()} | {:running, pos_integer()} | {:error, term()}
  def start(project_root, origin, base, say) do
    with {:ok, target} <- resolve(project_root, origin, base) do
      Drain.run(target.state_root, %{
        recover: fn -> recover(target) end,
        statuses: fn -> statuses(target) end,
        build: &build(&1, target),
        say: say
      })
    end
  end

  @spec detach(Path.t(), Path.t() | nil, String.t() | nil) ::
          {:ok, pos_integer(), Path.t()} | {:running, pos_integer()} | {:error, term()}
  def detach(project_root, origin, base) do
    with {:ok, target} <- resolve(project_root, origin, base),
         :stopped <- Lock.state(target.state_root),
         {:ok, argv} <- relaunch_argv(target),
         :ok <- File.mkdir_p(target.state_root),
         log = Lock.log_path(target.state_root),
         {:ok, result} <-
           Proc.run(["/usr/bin/perl", "-e", @detach_script, log | argv],
             cd: project_root,
             env: System.get_env(),
             timeout_ms: 10_000
           ) do
      detached(result, log)
    end
  end

  defp detached(%{exit_status: 0, output_tail: output}, log) do
    case Integer.parse(String.trim(output)) do
      {pid, ""} -> {:ok, pid, log}
      _invalid -> {:error, {:queue_detach_failed, output}}
    end
  end

  defp detached(%{output_tail: output}, _log), do: {:error, {:queue_detach_failed, output}}

  @spec stop(Path.t(), Path.t() | nil, String.t() | nil) ::
          {:stopping, pos_integer()} | :not_running | {:error, term()}
  def stop(project_root, origin, base) do
    with {:ok, target} <- resolve(project_root, origin, base) do
      Lock.request_stop(target.state_root)
    end
  end

  @spec interrupt(Path.t()) :: :ok | {:error, term()}
  def interrupt(project_root) do
    with {:ok, home} <- RuntimeDiscovery.home() do
      StateView.interrupt(
        Workspaces.root(project_root, home),
        String.to_integer(System.pid())
      )
    end
  end

  defp resolve(project_root, origin, base) do
    with {:ok, runtime} <- RuntimeDiscovery.runtime(),
         {:ok, home} <- home(runtime),
         {:ok, project} <- Kogen.Project.load(project_root),
         git_env = Runtime.git_environment(runtime.base_env),
         {:ok, origin, base} <-
           ProjectContext.resolve(project_root, project, origin, base, git_env) do
      {:ok,
       %QueueTarget{
         root: project_root,
         origin: origin,
         base: base,
         git_env: git_env,
         state_root: Workspaces.root(project_root, home)
       }}
    end
  end

  defp recover(target),
    do:
      Recovery.recover(target.root, target.state_root, target.origin, target.base, target.git_env)

  defp statuses(target),
    do: Status.list(target.root, target.state_root, target.origin, target.base, target.git_env)

  defp build(slug, target) do
    options = %BuildOptions{
      slug: slug,
      project_root: target.root,
      origin: target.origin,
      base: target.base
    }

    case Kogen.Kernel.build(options) do
      {:ok, %Result{} = result} ->
        {:ok,
         %{
           slug: slug,
           status: result.status,
           run_id: result.run_id,
           landed_sha: result.landed_sha,
           class: result.failure && result.failure.class,
           reason: failure_reason(result)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp failure_reason(%Result{status: :landed}), do: nil
  defp failure_reason(%Result{failure: %{reason: reason}}), do: to_string(reason)
  defp failure_reason(%Result{reason: reason}), do: inspect(reason)

  defp relaunch_argv(target) do
    case RuntimeDiscovery.script() do
      {:ok, script} when is_binary(script) ->
        escript = Path.join(RuntimeDiscovery.erts_bin(), "escript")

        {:ok,
         [escript, script, "queue", "start", "--project", target.root] ++
           ["--origin", target.origin, "--base", target.base]}

      {:ok, nil} ->
        {:error, :detach_needs_installed_kogen}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp home(runtime) do
    case Runtime.home(runtime) do
      home when is_binary(home) -> {:ok, home}
      nil -> RuntimeDiscovery.home()
    end
  end
end
