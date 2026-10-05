defmodule Kogen.Kernel.InstallLocalTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc

  @repo_root Path.expand("../..", __DIR__)

  test "installed launcher uses its build OTP despite the project escript on PATH", %{
    tmp_dir: tmp_dir
  } do
    project = Path.join(tmp_dir, "project")
    install_home = Path.join(tmp_dir, "install-home")
    File.mkdir_p!(project)

    assert {:ok, runtime} = Kogen.Kernel.runtime()
    alternate_erlang = installed_alternate_erlang(runtime.base_env)

    if alternate_erlang do
      File.write!(Path.join(project, ".tool-versions"), "erlang #{alternate_erlang}\n")
    end

    # Build into a private directory so this test never waits on, or breaks, the
    # build lock and consolidated protocols of the suite's own _build (prod needs
    # only the app and the boundary compiler, so the build stays quick).
    build_env = %{"MIX_ENV" => "prod", "MIX_BUILD_PATH" => Path.join(tmp_dir, "mix-build")}

    assert {:ok, %ProcResult{exit_status: 0, output_tail: install_output}} =
             Proc.run(
               ["make", "install-local", "KOGEN_INSTALL_HOME=#{install_home}"],
               cd: @repo_root,
               env: Map.merge(runtime.base_env, build_env)
             )

    assert is_binary(install_output)

    launcher = Path.join([install_home, ".local", "bin", "kogen"])
    assert File.regular?(launcher)

    %ProcResult{exit_status: status, output_tail: output} =
      case alternate_erlang do
        nil ->
          assert_stub_escript_is_first!(tmp_dir, project, launcher, runtime.base_env)

        version ->
          run_with_mise_toolchain!(project, launcher, version, runtime)
      end

    assert status == 0, "installed launcher failed:\n#{output}"
    assert output =~ "Commands:"
    assert output =~ "  status      "
  end

  defp installed_alternate_erlang(env) do
    home = Map.fetch!(env, "HOME")
    data_dir = Map.get(env, "MISE_DATA_DIR", Path.join([home, ".local", "share", "mise"]))
    installs = Path.join([data_dir, "installs", "erlang"])

    current =
      :code.root_dir()
      |> List.to_string()
      |> Path.join("../..")
      |> Path.expand()
      |> Path.basename()

    case File.ls(installs) do
      {:ok, versions} ->
        versions = Enum.filter(versions, &File.dir?(Path.join(installs, &1)))

        Enum.find(versions, &(&1 != current && &1 == "27.3")) ||
          Enum.find(versions, &(&1 != current))

      {:error, _reason} ->
        nil
    end
  end

  defp assert_stub_escript_is_first!(tmp_dir, project, launcher, env) do
    stub_bin = Path.join(tmp_dir, "stub-bin")
    stub = Path.join(stub_bin, "escript")
    File.mkdir_p!(stub_bin)
    File.write!(stub, "#!/bin/sh\nexit 1\n")
    File.chmod!(stub, 0o755)

    test_env = Map.update!(env, "PATH", &Enum.join([stub_bin, &1], ":"))

    assert %ProcResult{exit_status: 0, output_tail: resolved} =
             run(["sh", "-c", "command -v escript"], project, test_env)

    assert String.trim(resolved) == stub
    run([launcher, "--help"], project, test_env)
  end

  defp run_with_mise_toolchain!(project, launcher, version, runtime) do
    mise = runtime.mise

    assert %ProcResult{exit_status: 0, output_tail: resolved} =
             run(
               [mise, "exec", "--", "sh", "-c", "command -v escript"],
               project,
               runtime.base_env
             )

    assert resolved =~ "/erlang/#{version}/bin/escript"
    run([mise, "exec", "--", launcher, "--help"], project, runtime.base_env)
  end

  defp run(argv, cd, env) do
    case Proc.run(argv, cd: cd, env: env) do
      {:ok, %ProcResult{} = result} -> result
      {:error, reason} -> raise "#{Enum.join(argv, " ")} failed: #{inspect(reason)}"
    end
  end
end
