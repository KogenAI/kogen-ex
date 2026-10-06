defmodule Kogen.Provider.ChatGPT.LockTest do
  use Kogen.Testkit.Case

  alias Kogen.Provider.ChatGPT.Lock

  test "runs the function under the lock and releases it", %{tmp_dir: root} do
    assert {:ok, :done} = Lock.with_lock(root, "login", fn -> :done end)
    assert {:ok, :again} = Lock.with_lock(root, "login", fn -> :again end)
  end

  test "reclaims a lock whose owner record is stale", %{tmp_dir: root} do
    write_owner!(root, "1 0 token")

    assert {:ok, :done} = Lock.with_lock(root, "login", fn -> :done end, timeout_ms: 2_000)
  end

  test "waits on a fresh lock until the deadline", %{tmp_dir: root} do
    write_owner!(root, "1 #{System.system_time(:millisecond)} token")

    assert {:error, :lock_timeout} =
             Lock.with_lock(root, "login", fn -> :done end, timeout_ms: 60)
  end

  for contents <- ["", "1 incomplete token", "incomplete"] do
    test "waits on a fresh incomplete owner record #{inspect(contents)}", %{tmp_dir: root} do
      write_owner!(root, unquote(contents))

      assert {:error, :lock_timeout} =
               Lock.with_lock(root, "login", fn -> :done end, timeout_ms: 60)
    end
  end

  test "reclaims an incomplete owner record only after its directory is stale", %{tmp_dir: root} do
    owner = write_owner!(root, "")
    File.touch!(Path.dirname(owner), 0)

    assert {:ok, :done} = Lock.with_lock(root, "login", fn -> :done end, timeout_ms: 2_000)
  end

  test "reports an unreadable owner record instead of assuming the lock is live", %{tmp_dir: root} do
    owner = write_owner!(root, "1 #{System.system_time(:millisecond)} token")
    File.chmod!(owner, 0o000)
    on_exit(fn -> File.chmod(owner, 0o600) end)

    assert {:error, :eacces} = Lock.with_lock(root, "login", fn -> :done end, timeout_ms: 2_000)
  end

  defp write_owner!(root, contents) do
    lock = Path.join([root, "locks", "login.lock"])
    File.mkdir_p!(lock)
    owner = Path.join(lock, "owner")
    File.write!(owner, contents)
    owner
  end
end
