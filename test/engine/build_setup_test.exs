defmodule Kogen.Engine.Build.SetupTest.FakeProc do
  @moduledoc false
  alias Kogen.Contracts.ProcResult

  @spec run([String.t()], keyword()) :: {:ok, ProcResult.t()}
  def run(argv, options) do
    send(Process.get({__MODULE__, :receiver}), {:run, argv, options})
    result = Process.get({__MODULE__, :result})

    {:ok,
     %ProcResult{
       argv: argv,
       exit_status: result.exit_status,
       timed_out: result.timed_out,
       output_tail: result.output_tail,
       log_path: Keyword.fetch!(options, :log_path),
       duration_ms: 0
     }}
  end
end

defmodule Kogen.Engine.Build.SetupTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Engine.Build.Setup
  alias Kogen.Engine.Build.SetupTest.FakeProc

  test "runs setup commands in order with the Candidate env and per-command logs", %{
    tmp_dir: tmp_dir
  } do
    Process.put({FakeProc, :receiver}, self())
    Process.put({FakeProc, :result}, successful_result())
    run_dir = Path.join(tmp_dir, "run")
    env = %{"PATH" => "/usr/bin:/bin", "APP_MODE" => "test"}

    assert :ok =
             Setup.run(
               [spec("assets", ["npm", "ci"]), spec("compile", ["mix", "compile"])],
               tmp_dir,
               run_dir,
               env,
               FakeProc
             )

    assert_receive {:run, ["npm", "ci"], first_options}
    assert first_options[:cd] == tmp_dir
    assert first_options[:env] == env
    assert first_options[:timeout_ms] == 5_000
    assert first_options[:log_path] == Path.join([run_dir, "logs", "setup-assets.log"])

    assert_receive {:run, ["mix", "compile"], second_options}
    assert second_options[:log_path] == Path.join([run_dir, "logs", "setup-compile.log"])
  end

  test "records setup failure name and only the output tail", %{tmp_dir: tmp_dir} do
    Process.put({FakeProc, :receiver}, self())
    diagnostic = String.duplicate("before-", 400) <> "latest setup output"

    Process.put({FakeProc, :result}, %ProcResult{
      argv: ["npm", "ci"],
      exit_status: 9,
      timed_out: false,
      output_tail: diagnostic,
      log_path: nil,
      duration_ms: 1
    })

    assert {:error, %Failure{class: :environment, reason: :setup_failed, detail: detail}} =
             Setup.run(
               [spec("assets", ["npm", "ci"])],
               tmp_dir,
               Path.join(tmp_dir, "run"),
               %{},
               FakeProc
             )

    assert detail =~ "setup command assets failed"
    assert detail =~ "latest setup output"
    assert byte_size(detail) <= 2_200
  end

  test "setup command exit statuses 126 and 127 are tool missing environment failures", %{
    tmp_dir: tmp_dir
  } do
    Process.put({FakeProc, :receiver}, self())

    for status <- [126, 127] do
      Process.put({FakeProc, :result}, %ProcResult{
        argv: ["mix", "compile"],
        exit_status: status,
        timed_out: false,
        output_tail: "command unavailable",
        log_path: nil,
        duration_ms: 1
      })

      assert {:error, %Failure{class: :environment, reason: :tool_missing}} =
               Setup.run(
                 [spec("compile", ["mix", "compile"])],
                 tmp_dir,
                 Path.join(tmp_dir, "setup-run-#{status}"),
                 %{},
                 FakeProc
               )
    end
  end

  test "runs real successful and failing setup commands through Proc", %{tmp_dir: tmp_dir} do
    env = %{"PATH" => "/usr/bin:/bin"}
    run_dir = Path.join(tmp_dir, "run")

    assert :ok = Setup.run([spec("true", ["true"])], tmp_dir, run_dir, env, Kogen.Proc)

    assert {:ok, _log} = File.read(Path.join([run_dir, "logs", "setup-true.log"]))

    assert {:error, %Failure{class: :environment, reason: :setup_failed, detail: detail}} =
             Setup.run([spec("false", ["false"])], tmp_dir, run_dir, env, Kogen.Proc)

    assert detail =~ "setup command false failed"
  end

  defp spec(name, argv), do: %CheckSpec{name: name, argv: argv, timeout_ms: 5_000}

  defp successful_result do
    %ProcResult{
      argv: [],
      exit_status: 0,
      timed_out: false,
      output_tail: "",
      log_path: nil,
      duration_ms: 0
    }
  end
end
