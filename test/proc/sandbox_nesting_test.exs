defmodule Kogen.Proc.SandboxNestingTest do
  use Kogen.Testkit.Case

  alias Kogen.Testkit.Proc, as: TestProc

  @wrapped [
    "/usr/bin/sandbox-exec",
    "-p",
    "PROFILE",
    "/usr/bin/env",
    "KOGEN_SANDBOXED=1",
    "/bin/true"
  ]

  # The marker is read from the OS environment at wrap time, so each case runs Sandbox.command/2
  # in a fresh BEAM spawned with (or without) KOGEN_SANDBOXED instead of mutating this VM's env.
  defp wrapped_command(tmp_dir, marker, enabled \\ true) do
    script = """
    sandbox = %Kogen.Proc.Sandbox{
      enabled: #{enabled},
      home: "#{tmp_dir}/home",
      project_root: "#{tmp_dir}/project",
      origin: "#{tmp_dir}/origin.git",
      workspace: "#{tmp_dir}/workspace",
      run_dir: "#{tmp_dir}/run",
      tmp_dir: "#{tmp_dir}"
    }

    {:ok, command} = Kogen.Proc.Sandbox.command(["/bin/true"], sandbox)
    command = if hd(command) =~ "sandbox-exec", do: List.replace_at(command, 2, "PROFILE"), else: command
    IO.puts(Enum.join(command, "\\n"))
    """

    "elixir"
    |> System.find_executable()
    |> TestProc.cmd!(
      ["-pa", Mix.Project.compile_path(), "-e", script],
      env: [{"KOGEN_SANDBOXED", marker}]
    )
    |> String.split("\n", trim: true)
  end

  test "inside Kogen's own sandbox, wrapping is a no-op", %{tmp_dir: tmp_dir} do
    assert wrapped_command(tmp_dir, "1") == ["/bin/true"]
  end

  test "outside Kogen's own sandbox, commands are wrapped in sandbox-exec", %{tmp_dir: tmp_dir} do
    if :os.type() == {:unix, :darwin} do
      assert wrapped_command(tmp_dir, nil) == @wrapped
    end
  end

  test "any other KOGEN_SANDBOXED value still wraps", %{tmp_dir: tmp_dir} do
    if :os.type() == {:unix, :darwin} do
      assert wrapped_command(tmp_dir, "0") == @wrapped
    end
  end

  test "children inherit the marker only when nested" do
    assert child_env("1") =~ ~s(%{"KOGEN_SANDBOXED" => "1"})
    assert child_env(nil) =~ "%{}"
  end

  defp child_env(marker) do
    TestProc.cmd!(
      System.find_executable("elixir"),
      ["-pa", Mix.Project.compile_path(), "-e", "IO.inspect(Kogen.Proc.Sandbox.child_env())"],
      env: [{"KOGEN_SANDBOXED", marker}]
    )
  end
end
