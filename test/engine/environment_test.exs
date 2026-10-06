defmodule Kogen.Engine.EnvironmentTest do
  use Kogen.Testkit.Case

  alias Kogen.Engine
  alias Kogen.Engine.Runtime

  test "runtime preserves the outer sandbox marker without exporting it to project commands" do
    runtime =
      Runtime.new(
        %{"PATH" => "/usr/bin:/bin", "KOGEN_SANDBOXED" => "1"},
        "/mise/bin/mise",
        nil,
        "/runtime",
        "/runtime/bin"
      )

    assert Runtime.sandboxed?(runtime)
    refute Runtime.sandboxed?(Runtime.process_env(runtime, %{}))
  end

  test "Build runs scope mise state and cache after inherited and project values", %{
    tmp_dir: tmp_dir
  } do
    run_dir = Path.join(tmp_dir, "run")
    workspace = Path.join(tmp_dir, "workspace")

    runtime =
      %{
        "PATH" => "/usr/bin:/bin",
        "HOME" => "/home/test",
        "MISE_STATE_DIR" => "/shared/mise-state",
        "MISE_CACHE_DIR" => "/shared/mise-cache"
      }
      |> Runtime.new(
        "/mise/bin/mise",
        nil,
        "/runtime",
        "/runtime/bin"
      )
      |> Runtime.for_run(run_dir)
      |> Runtime.trust_workspace(workspace)

    assert runtime.base_env["MISE_STATE_DIR"] == Path.join(run_dir, "mise-state")
    assert runtime.base_env["MISE_CACHE_DIR"] == Path.join(run_dir, "mise-cache")

    process_env =
      runtime.base_env
      |> Map.merge(%{
        "MISE_STATE_DIR" => "/project/mise-state",
        "MISE_CACHE_DIR" => "/project/mise-cache",
        "MISE_TRUSTED_CONFIG_PATHS" => "/project/trusted"
      })
      |> Runtime.for_run(run_dir)
      |> Runtime.trust_workspace(workspace)

    assert process_env["MISE_STATE_DIR"] == Path.join(run_dir, "mise-state")
    assert process_env["MISE_CACHE_DIR"] == Path.join(run_dir, "mise-cache")
    assert process_env["MISE_TRUSTED_CONFIG_PATHS"] == workspace
  end

  test "adds a trusted workspace without dropping existing mise trust paths", %{tmp_dir: tmp_dir} do
    existing = Path.join(tmp_dir, "bench-config")
    workspace = Path.join(tmp_dir, "workspace")

    env = Runtime.add_trusted_workspace(%{"MISE_TRUSTED_CONFIG_PATHS" => existing}, workspace)

    assert env["MISE_TRUSTED_CONFIG_PATHS"] == Enum.join([existing, workspace], ":")
  end

  test "includes mise failure output in the toolchain error", %{tmp_dir: tmp_dir} do
    mise = Path.join(tmp_dir, "mise")
    File.write!(mise, "#!/bin/sh\nprintf '%s\\n' 'mise diagnostic output'\nexit 17\n")
    File.chmod!(mise, 0o755)

    runtime = Runtime.new(%{"PATH" => "/usr/bin:/bin"}, mise, nil, "/runtime", "/runtime/bin")

    assert {:error, {:toolchain_failed, detail}} = Engine.project_environment(tmp_dir, runtime)
    assert detail =~ "mise env failed"
    assert detail =~ "mise diagnostic output"
  end
end
