defmodule KogenChecks.CapabilityGuardTest do
  use ExUnit.Case, async: true

  test "rejects process primitives outside the process adapters" do
    for call <- [
          ~s{System.cmd("git", ["status"]) },
          "System.shell(\"git status\")",
          "Port.open({:spawn, \"git status\"}, [])",
          ":os.cmd(\"true\")"
        ] do
      assert_compile_failure(call, "must be called through Kogen.Proc")
    end
  end

  test "rejects ambient discovery outside Kernel" do
    for call <- [
          "System.get_env(\"HOME\")",
          "File.cwd!()",
          "File.cwd()",
          "System.user_home()",
          "System.user_home!()"
        ] do
      assert_compile_failure(call, "only Kogen.Kernel.* may call it")
    end
  end

  test "rejects global mutation and sleeps in lib and test modules" do
    for call <- [
          "File.cd!(\"/\")",
          "File.cd(\"/\")",
          ~s{System.put_env("KOGEN_TEST", "1")},
          "System.delete_env(\"KOGEN_TEST\")",
          "Application.put_env(:kogen, :key, :value)",
          "Process.sleep(1)",
          ":timer.sleep(1)"
        ] do
      assert_compile_failure(call, "mutates process-global state")
    end
  end

  test "permits the process adapters and Kernel ambient reads" do
    compile_module(Kogen.Proc.GuardProbe, ~s{System.cmd("git", ["status"]) })

    compile_module(
      Kogen.Testkit.ProcGuardProbe,
      ~s{System.cmd("git", ["status"]) },
      "test/support/testkit/proc.ex"
    )

    compile_module(
      Kogen.Kernel.Config,
      "{System.get_env(\"HOME\"), File.cwd!(), System.user_home!()}"
    )

    assert :ok
  end

  defp assert_compile_failure(call, message) do
    error =
      assert_raise CompileError, fn ->
        caller = Module.concat(["Kogen", "Planted#{System.unique_integer([:positive])}"])
        compile_module(caller, call)
      end

    assert error.description =~ message
  end

  defp compile_module(module, body, file \\ "test/planted_capability.exs") do
    source = "defmodule #{inspect(module)} do\n  def run, do: #{body}\nend\n"
    Code.compile_string(source, file)
  end
end
