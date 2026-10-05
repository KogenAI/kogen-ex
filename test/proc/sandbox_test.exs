defmodule Kogen.Proc.SandboxTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Proc.Sandbox

  @tag :seatbelt
  test "Seatbelt confines writes and denies credential access", %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    project = Path.join(tmp_dir, "project")
    origin = Path.join(tmp_dir, "origin.git")
    workspace = Path.join([home, ".kogen", "workspaces", "demo", "run-1"])
    run_dir = Path.join([home, ".kogen", "workspaces", "demo", "runs", "run-1"])
    credential = Path.join([home, ".codex", "auth.json"])
    kogen_credential = Path.join([home, ".kogen", "credentials-test.json"])
    encrypted_credential = Path.join([home, ".kogen", "credentials", "chatgpt-default.enc"])

    for path <- [
          home,
          project,
          origin,
          workspace,
          run_dir,
          Path.dirname(credential),
          Path.dirname(encrypted_credential)
        ] do
      File.mkdir_p!(path)
    end

    File.write!(credential, "fake-token")
    File.write!(kogen_credential, "fake-kogen-token")
    File.write!(encrypted_credential, "fake-encrypted-kogen-token")

    sandbox = %Sandbox{
      enabled: true,
      home: home,
      project_root: project,
      origin: origin,
      workspace: workspace,
      run_dir: run_dir,
      tmp_dir: tmp_dir
    }

    env = %{
      "PATH" => "/usr/bin:/bin",
      "HOME" => home,
      "PROJECT_ROOT" => project,
      "ORIGIN_ROOT" => origin,
      "KOGEN_CREDENTIAL" => kogen_credential
    }

    assert {:ok, profile} = Sandbox.profile(sandbox)
    assert profile =~ "(allow file-write*"
    assert profile =~ ".codex"
    assert profile =~ "(deny file-write*"

    in_place_sandbox = %{
      sandbox
      | project_root: project,
        origin: project,
        workspace: project,
        workspace_is_project: true
    }

    assert {:ok, in_place_profile} = Sandbox.profile(in_place_sandbox)
    assert in_place_profile =~ "(allow file-write* (subpath "

    assert {:ok, protected_in_place_profile} =
             Sandbox.profile(%{in_place_sandbox | workspace_is_project: false})

    project_deny =
      protected_in_place_profile
      |> String.split("\n")
      |> Enum.find(fn line ->
        String.starts_with?(line, "(deny file-write* (subpath ") and
          String.ends_with?(line, "/project\"))")
      end)

    assert is_binary(project_deny)
    refute project_deny in String.split(in_place_profile, "\n")

    if :os.type() == {:unix, :darwin} do
      assert_sandbox_denies(
        ["/bin/sh", "-c", "printf escaped > \"$PROJECT_ROOT/outside.txt\""],
        workspace,
        env,
        sandbox
      )

      refute File.exists?(Path.join(project, "outside.txt"))

      assert_sandbox_denies(
        ["/bin/sh", "-c", "printf escaped > \"$ORIGIN_ROOT/outside.txt\""],
        workspace,
        env,
        sandbox
      )

      refute File.exists?(Path.join(origin, "outside.txt"))

      assert_sandbox_denies(["/bin/cat", credential], workspace, env, sandbox)
      assert_sandbox_denies(["/bin/cat", kogen_credential], workspace, env, sandbox)
      assert_sandbox_denies(["/bin/cat", encrypted_credential], workspace, env, sandbox)

      assert_sandbox_denies(
        ["/bin/sh", "-c", "printf escaped > \"$KOGEN_CREDENTIAL\""],
        workspace,
        env,
        sandbox
      )

      assert File.read!(kogen_credential) == "fake-kogen-token"

      assert_sandbox_denies(
        ["/bin/sh", "-c", "printf escaped > \"$ENCRYPTED_CREDENTIAL\""],
        workspace,
        Map.put(env, "ENCRYPTED_CREDENTIAL", encrypted_credential),
        sandbox
      )

      assert File.read!(encrypted_credential) == "fake-encrypted-kogen-token"

      assert {:ok, %ProcResult{exit_status: 0, timed_out: false}} =
               Proc.run(["/bin/sh", "-c", "printf allowed > workspace-write.txt"],
                 cd: workspace,
                 env: env,
                 sandbox: sandbox
               )

      assert File.read!(Path.join(workspace, "workspace-write.txt")) == "allowed"

      assert {:ok, %ProcResult{exit_status: 0, timed_out: false}} =
               Proc.run(["/bin/sh", "-c", "printf allowed > \"$RUN_DIR/run-output.log\""],
                 cd: workspace,
                 env: Map.put(env, "RUN_DIR", run_dir),
                 sandbox: sandbox
               )

      assert File.read!(Path.join(run_dir, "run-output.log")) == "allowed"

      shared_tmp_file =
        Path.join("/tmp", "kogen-sandbox-#{System.unique_integer([:positive])}.txt")

      try do
        assert {:ok, %ProcResult{exit_status: 0, timed_out: false}} =
                 Proc.run(["/bin/sh", "-c", "printf allowed > \"$SHARED_TMP_FILE\""],
                   cd: workspace,
                   env: Map.put(env, "SHARED_TMP_FILE", shared_tmp_file),
                   sandbox: sandbox
                 )

        assert File.read!(shared_tmp_file) == "allowed"
      after
        File.rm(shared_tmp_file)
      end
    else
      assert Sandbox.command(["/bin/true"], sandbox) == {:ok, ["/bin/true"]}
    end
  end

  @tag :seatbelt
  test "mise exec trusts an external config with run-local state in the sandbox", %{
    tmp_dir: tmp_dir
  } do
    home = Path.join(tmp_dir, "home")
    project = Path.join(tmp_dir, "project")
    origin = Path.join(tmp_dir, "origin.git")
    workspace = Path.join(tmp_dir, "workspace")
    run_dir = Path.join(tmp_dir, "run")
    config_dir = Path.join(tmp_dir, "mise-config")
    sandbox_tmp = Path.join(tmp_dir, "tmp")

    for path <- [home, project, origin, workspace, run_dir, config_dir, sandbox_tmp],
        do: File.mkdir_p!(path)

    File.mkdir_p!(Path.join([workspace, "test", "acceptance"]))

    File.write!(
      Path.join(workspace, "mix.exs"),
      "defmodule SandboxProbe.MixProject do\n" <>
        "  use Mix.Project\n" <>
        ~s(  def project, do: [app: :sandbox_probe, version: "0.1.0", elixir: "~> 1.20"]\n) <>
        "end\n"
    )

    File.write!(Path.join([workspace, "test", "test_helper.exs"]), "ExUnit.start()\n")
    File.write!(Path.join([workspace, "test", "acceptance", "compile_test.exs"]), "")

    mise_config = Path.join(config_dir, "mise.toml")

    File.write!(
      mise_config,
      ~s([tools]\nelixir = "1.20.4-otp-29"\nerlang = "29.1.1"\n) <>
        "[env]\nKOGEN_MISE_SANDBOX_TEST = \"trusted\"\n"
    )

    mise = System.find_executable("mise")
    assert is_binary(mise), "mise must be available to the sandbox regression test"

    path =
      Enum.join(
        [
          Path.dirname(mise),
          "/opt/bench/mise/installs/elixir/1.20.2-otp-29/bin",
          "/opt/bench/mise/installs/erlang/29.0.3/bin",
          "/usr/bin",
          "/bin"
        ],
        ":"
      )

    state_dir = Path.join(run_dir, "mise-state")
    cache_dir = Path.join(run_dir, "mise-cache")

    elixir = System.find_executable("elixir")
    assert is_binary(elixir), "Elixir must be available through mise for the sandbox test"

    data_dir =
      elixir
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()

    env = %{
      "HOME" => home,
      "PATH" => path,
      "TMPDIR" => sandbox_tmp,
      "MISE_CONFIG_DIR" => config_dir,
      "MISE_CONFIG_FILE" => mise_config,
      "MISE_DATA_DIR" => data_dir,
      "MISE_TRUSTED_CONFIG_PATHS" => Enum.join([workspace, config_dir], ":"),
      "MISE_STATE_DIR" => state_dir,
      "MISE_CACHE_DIR" => cache_dir,
      "MIX_ENV" => "test",
      "MIX_HOME" => Path.join(sandbox_tmp, "mix-home")
    }

    sandbox = %Sandbox{
      enabled: true,
      home: home,
      project_root: project,
      origin: origin,
      workspace: workspace,
      run_dir: run_dir,
      tmp_dir: sandbox_tmp
    }

    assert {:ok, %ProcResult{exit_status: 0, timed_out: false}} =
             Proc.run(
               [
                 mise,
                 "exec",
                 "--",
                 "/bin/sh",
                 "-c",
                 "test \"$KOGEN_MISE_SANDBOX_TEST\" = trusted && " <>
                   "mix test --dry-run test/acceptance/compile_test.exs"
               ],
               cd: workspace,
               env: env,
               sandbox: sandbox
             )

    assert_link_targets(
      Path.join(state_dir, "tracked-configs"),
      Path.join(Path.basename(config_dir), "mise.toml")
    )
  end

  defp assert_link_targets(directory, suffix) do
    assert Enum.any?(Path.wildcard(Path.join(directory, "*")), fn path ->
             case File.read_link(path) do
               {:ok, target} -> String.ends_with?(target, suffix)
               {:error, _reason} -> false
             end
           end)
  end

  defp assert_sandbox_denies(argv, workspace, env, sandbox) do
    assert {:ok, %ProcResult{exit_status: status, timed_out: false, output_tail: output}} =
             Proc.run(argv, cd: workspace, env: env, sandbox: sandbox)

    assert status != 0
    refute output =~ "fake-token"
  end
end
