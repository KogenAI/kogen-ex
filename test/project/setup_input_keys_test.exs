defmodule Kogen.Project.SetupInputKeysTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project
  alias Kogen.Project.SetupReuse

  @env %{"PATH" => "/usr/bin:/bin", "MIX_ENV" => "test"}
  @base String.duplicate("a", 40)

  test "declared inputs reuse prepared files across source changes and isolate Candidates", %{
    tmp_dir: root
  } do
    config = project(root)
    first = workspace(root, "first", "lock-v1")
    second = workspace(root, "second", "lock-v1")
    File.write!(Path.join(second, "source.ex"), "unrelated source edit")
    cache = Path.join(root, "cache")

    assert {:ok, %{reused?: false, wall_ms: time}} = prepare(config, first, cache, @base, @env)
    assert time >= 0

    assert {:ok, %{reused?: true, saved_wall_ms: ^time} = result} =
             SetupReuse.run(config, second, cache, String.duplicate("b", 40), @env, fn ->
               flunk("setup reran")
             end)

    assert File.read!(Path.join(second, "_build/ready")) == "lock-v1"
    File.write!(Path.join(second, "_build/ready"), "Candidate edits")
    third = workspace(root, "third", "lock-v1")

    assert {:ok, %{reused?: true}} =
             SetupReuse.run(config, third, cache, @base, @env, fn -> flunk("setup reran") end)

    assert File.read!(Path.join(third, "_build/ready")) == "lock-v1"
    assert :ok = SetupReuse.record_reuse(Path.join(root, "journal"), result)
    assert File.read!(Path.join(root, "journal/events.jsonl")) =~ "setup_reused"
  end

  test "each input and the environment invalidates the prepared files", %{tmp_dir: root} do
    config = project(root)
    first = workspace(root, "first", "lock-v1")
    cache = Path.join(root, "cache")
    assert {:ok, %{reused?: false}} = prepare(config, first, cache, @base, @env)

    for {name, lock, toolchain, env} <- [
          {"lock", "lock-v2", "tool-v1", @env},
          {"tool", "lock-v1", "tool-v2", @env},
          {"env", "lock-v1", "tool-v1", Map.put(@env, "MIX_ENV", "dev")}
        ] do
      next = workspace(root, name, lock)
      File.write!(Path.join(next, "mise.toml"), toolchain)
      assert {:ok, %{reused?: false}} = prepare(config, next, cache, @base, env)
      assert File.read!(Path.join(next, "_build/ready")) == lock
    end
  end

  test "missing and symlinked inputs miss safely and preserve ordinary setup errors", %{
    tmp_dir: root
  } do
    config = project(root)
    first = workspace(root, "first", "lock-v1")
    cache = Path.join(root, "cache")
    assert {:ok, %{reused?: false}} = prepare(config, first, cache, @base, @env)

    for name <- ["missing", "symlink"] do
      next = workspace(root, name, "lock-v1")
      File.rm!(Path.join(next, "mix.lock"))

      if name == "symlink",
        do: File.ln_s!(Path.join(first, "mix.lock"), Path.join(next, "mix.lock"))

      assert {:error, :ordinary_setup_failure} =
               SetupReuse.run(config, next, cache, @base, @env, fn ->
                 {:error, :ordinary_setup_failure}
               end)

      refute File.exists?(Path.join(next, "_build/ready"))
    end
  end

  test "setup that changes its own input cannot publish under the earlier key", %{tmp_dir: root} do
    config = project(root)
    first = workspace(root, "first", "lock-v1")
    cache = Path.join(root, "cache")

    assert {:ok, %{reused?: false}} =
             SetupReuse.run(config, first, cache, @base, @env, fn ->
               File.write!(Path.join(first, "mix.lock"), "changed during setup")
               output!(first, "unsafe")
               :ok
             end)

    second = workspace(root, "second", "lock-v1")
    assert {:ok, %{reused?: false}} = prepare(config, second, cache, @base, @env)
    assert File.read!(Path.join(second, "_build/ready")) == "lock-v1"
  end

  test "absolute cached links point into each restored Candidate", %{tmp_dir: root} do
    config = project(root)
    first = workspace(root, "first", "lock-v1")
    cache = Path.join(root, "cache")

    assert {:ok, %{reused?: false}} =
             SetupReuse.run(config, first, cache, @base, @env, fn ->
               output!(first, "original")
               File.ln_s!(Path.join(first, "_build/ready"), Path.join(first, "_build/link"))
               :ok
             end)

    second = workspace(root, "second", "lock-v1")
    assert {:ok, %{reused?: true}} = prepare(config, second, cache, @base, @env)
    File.write!(Path.join(second, "_build/link"), "Candidate writes")
    assert File.read!(Path.join(first, "_build/ready")) == "original"
    third = workspace(root, "third", "lock-v1")
    assert {:ok, %{reused?: true}} = prepare(config, third, cache, @base, @env)
    assert File.read!(Path.join(third, "_build/link")) == "original"
  end

  defp prepare(config, root, cache, base, env) do
    SetupReuse.run(config, root, cache, base, env, fn ->
      output!(root, File.read!(Path.join(root, "mix.lock")))
      :ok
    end)
  end

  defp project(root) do
    %Project{
      root: root,
      name: "inputs",
      checks: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{},
      setup: [%CheckSpec{name: "prepare", argv: ["prepare"], timeout_ms: 1000}],
      setup_outputs: ["_build"],
      setup_inputs: ["mix.lock", "mise.toml"]
    }
  end

  defp workspace(root, name, lock) do
    directory = Path.join(root, name)
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "mix.lock"), lock)
    File.write!(Path.join(directory, "mise.toml"), "tool-v1")
    directory
  end

  defp output!(root, value) do
    File.mkdir_p!(Path.join(root, "_build"))
    File.write!(Path.join(root, "_build/ready"), value)
  end
end
