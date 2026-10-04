defmodule Kogen.Engine.EnvironmentTest do
  use Kogen.Testkit.Case

  alias Kogen.Engine.Environment
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
      |> Runtime.for_build_run(run_dir)

    assert runtime.base_env["MISE_STATE_DIR"] == Path.join(run_dir, "mise-state")
    assert runtime.base_env["MISE_CACHE_DIR"] == Path.join(run_dir, "mise-cache")

    process_env =
      Runtime.for_build_run(
        Map.merge(runtime.base_env, %{
          "MISE_STATE_DIR" => "/project/mise-state",
          "MISE_CACHE_DIR" => "/project/mise-cache"
        }),
        run_dir
      )

    assert process_env["MISE_STATE_DIR"] == Path.join(run_dir, "mise-state")
    assert process_env["MISE_CACHE_DIR"] == Path.join(run_dir, "mise-cache")
  end

  test "includes mise failure output in the toolchain error", %{tmp_dir: tmp_dir} do
    mise = Path.join(tmp_dir, "mise")
    File.write!(mise, "#!/bin/sh\nprintf '%s\\n' 'mise diagnostic output'\nexit 17\n")
    File.chmod!(mise, 0o755)

    runtime = Runtime.new(%{"PATH" => "/usr/bin:/bin"}, mise, nil, "/runtime", "/runtime/bin")

    assert {:error, {:toolchain_failed, detail}} = Environment.project(tmp_dir, runtime)
    assert detail =~ "mise env failed"
    assert detail =~ "mise diagnostic output"
  end
end
