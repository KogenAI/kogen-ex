defmodule Kogen.Project.SetupReuseTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project
  alias Kogen.Project.SetupReuse

  @base_sha String.duplicate("a", 40)
  @other_base_sha String.duplicate("b", 40)
  @toolchain_env %{"PATH" => "/usr/bin:/bin", "ELIXIR_VERSION" => "1.20.4"}

  test "reuses setup outputs for the same key and records the saved wall time", %{tmp_dir: root} do
    cache_root = Path.join(root, "setup-cache")
    source = workspace(root, "source")
    destination = workspace(root, "destination")
    config = project(root)
    parent = self()

    assert {:ok, %{reused?: false, key: key}} =
             run(config, source, cache_root, @base_sha, fn ->
               send(parent, :setup_ran)
               write_output(source, "prepared")
               :ok
             end)

    assert_receive :setup_ran

    assert {:ok, %{reused?: true, key: ^key, saved_wall_ms: saved_wall_ms} = result} =
             run(config, destination, cache_root, @base_sha, fn ->
               send(parent, :unexpected_setup)
               :ok
             end)

    assert saved_wall_ms >= 0
    assert File.read!(Path.join([destination, "_build", "result"])) == "prepared"
    assert :ok = SetupReuse.record_reuse(Path.join(root, "run"), result)

    assert File.read!(Path.join([root, "run", "events.jsonl"])) =~
             ~s("event":"setup_reused","setup_key":"#{key}","saved_wall_ms":)

    refute_receive :unexpected_setup
  end

  test "does not reuse after the setup spec, project env, or base tree changes", %{tmp_dir: root} do
    cache_root = Path.join(root, "setup-cache")
    original = project(root)
    parent = self()

    assert {:ok, %{reused?: false}} =
             run(
               original,
               workspace(root, "one"),
               cache_root,
               @base_sha,
               successful_setup(parent)
             )

    changed_spec = project(root, ["mix", "compile", "--force"])
    changed_env = %{original | env: %{"MIX_ENV" => "dev"}}

    for {config, base_sha, workspace_name} <- [
          {changed_spec, @base_sha, "two"},
          {changed_env, @base_sha, "three"},
          {original, @other_base_sha, "four"}
        ] do
      assert {:ok, %{reused?: false}} =
               run(
                 config,
                 workspace(root, workspace_name),
                 cache_root,
                 base_sha,
                 successful_setup(parent)
               )

      assert_receive :setup_ran
    end
  end

  test "a failed setup is not cached", %{tmp_dir: root} do
    cache_root = Path.join(root, "setup-cache")
    config = project(root)
    failed_workspace = workspace(root, "failed")

    assert {:error, :setup_failed} =
             run(config, failed_workspace, cache_root, @base_sha, fn ->
               {:error, :setup_failed}
             end)

    refute File.dir?(cache_root)

    parent = self()
    successful_workspace = workspace(root, "successful")

    assert {:ok, %{reused?: false}} =
             run(config, successful_workspace, cache_root, @base_sha, successful_setup(parent))

    assert_receive :setup_ran

    assert {:ok, %{reused?: true}} =
             run(config, workspace(root, "reused"), cache_root, @base_sha, fn ->
               send(parent, :unexpected_setup)
               :ok
             end)

    refute_receive :unexpected_setup
  end

  test "Candidate writes to a restored output do not change the cached tree", %{tmp_dir: root} do
    cache_root = Path.join(root, "setup-cache")
    config = project(root)
    parent = self()

    assert {:ok, %{reused?: false}} =
             run(config, workspace(root, "prepared"), cache_root, @base_sha, fn ->
               send(parent, :setup_ran)
               write_output(Path.join(root, "prepared"), "cache value")
               :ok
             end)

    assert_receive :setup_ran

    candidate = workspace(root, "candidate")

    assert {:ok, %{reused?: true}} =
             run(config, candidate, cache_root, @base_sha, fn ->
               send(parent, :unexpected_setup)
               :ok
             end)

    File.write!(Path.join([candidate, "_build", "result"]), "Candidate mutation")

    next_candidate = workspace(root, "next-candidate")

    assert {:ok, %{reused?: true}} =
             run(config, next_candidate, cache_root, @base_sha, fn ->
               send(parent, :unexpected_setup)
               :ok
             end)

    assert File.read!(Path.join([next_candidate, "_build", "result"])) == "cache value"
    refute_receive :unexpected_setup
  end

  test "keeps only the newest three prepared setups", %{tmp_dir: root} do
    cache_root = Path.join(root, "setup-cache")
    parent = self()
    first_config = project(root, ["mix", "compile", "1"])
    last_config = project(root, ["mix", "compile", "4"])

    for index <- 1..4 do
      config = project(root, ["mix", "compile", Integer.to_string(index)])

      assert {:ok, %{reused?: false}} =
               run(
                 config,
                 workspace(root, "run-#{index}"),
                 cache_root,
                 @base_sha,
                 fn ->
                   send(parent, :setup_ran)
                   write_output(Path.join(root, "run-#{index}"), "#{index}")
                   :ok
                 end
               )

      assert_receive :setup_ran
    end

    entries =
      cache_root
      |> File.ls!()
      |> Enum.map(&Path.join(cache_root, &1))
      |> Enum.filter(&File.regular?(Path.join(&1, "complete")))

    assert length(entries) == 3

    assert {:ok, %{reused?: false}} =
             run(first_config, workspace(root, "first-again"), cache_root, @base_sha, fn ->
               send(parent, :evicted_setup_ran)
               :ok
             end)

    assert_receive :evicted_setup_ran

    assert {:ok, %{reused?: true}} =
             run(last_config, workspace(root, "last-again"), cache_root, @base_sha, fn ->
               send(parent, :unexpected_setup)
               :ok
             end)

    refute_receive :unexpected_setup
  end

  defp run(project, workdir, cache_root, base_sha, runner) do
    SetupReuse.run(project, workdir, cache_root, base_sha, @toolchain_env, runner)
  end

  defp successful_setup(parent) do
    fn ->
      send(parent, :setup_ran)
      :ok
    end
  end

  defp project(root, argv \\ ["mix", "compile"]) do
    %Project{
      root: root,
      name: "setup-cache-test",
      checks: [],
      setup: [%CheckSpec{name: "compile", argv: argv, timeout_ms: 5_000}],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{},
      setup_outputs: ["_build"],
      env: %{},
      sandbox: true
    }
  end

  defp workspace(root, name) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    path
  end

  defp write_output(workdir, value) do
    path = Path.join([workdir, "_build", "result"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, value)
  end
end
