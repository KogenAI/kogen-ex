defmodule Kogen.Queue.DrainTest do
  use Kogen.Testkit.Case

  alias Kogen.Queue.Drain
  alias Kogen.Queue.IntentStatus
  alias Kogen.Queue.Lock

  test "builds approved Intents oldest approval first and goes on after a candidate failure", %{
    tmp_dir: tmp_dir
  } do
    {:ok, states} =
      Agent.start_link(fn ->
        %{"late" => {:approved, 30}, "early" => {:approved, 10}, "mid" => {:approved, 20}}
      end)

    outcomes = %{
      "early" => outcome("early", :landed, nil),
      "mid" => outcome("mid", :failed, :candidate),
      "late" => outcome("late", :landed, nil)
    }

    {:ok, lines} = Agent.start_link(fn -> [] end)

    assert {:ok, %{builds: builds, stop: :empty}} =
             Drain.run(tmp_dir, hooks(states, outcomes, lines))

    assert Enum.map(builds, & &1.slug) == ["early", "mid", "late"]

    assert Agent.get(lines, &Enum.reverse/1) == [
             "building early\n",
             "landed early abcdef12 (Build run-earl)\n",
             "building mid\n",
             "failed mid: candidate/gate_red (Build run-mid)\n",
             "building late\n",
             "landed late abcdef12 (Build run-late)\n"
           ]

    refute File.exists?(Path.join(tmp_dir, "queue.pid"))
  end

  test "a changed approved acceptance test fails only its Intent", %{tmp_dir: tmp_dir} do
    {:ok, states} = Agent.start_link(fn -> %{"a" => {:approved, 1}, "b" => {:approved, 2}} end)
    failed = %{outcome("a", :failed, :candidate) | reason: "approved_acceptance_changed"}
    outcomes = %{"a" => failed, "b" => outcome("b", :landed, nil)}
    {:ok, lines} = Agent.start_link(fn -> [] end)

    assert {:ok, %{builds: [^failed, %{slug: "b", status: :landed}], stop: :empty}} =
             Drain.run(tmp_dir, hooks(states, outcomes, lines))

    assert "failed a: candidate/approved_acceptance_changed (Build run-a)\n" in Agent.get(
             lines,
             & &1
           )
  end

  test "stops on an environment failure", %{tmp_dir: tmp_dir} do
    {:ok, states} = Agent.start_link(fn -> %{"a" => {:approved, 1}, "b" => {:approved, 2}} end)
    outcomes = %{"a" => outcome("a", :failed, :environment)}
    {:ok, lines} = Agent.start_link(fn -> [] end)

    assert {:ok, %{builds: [%{slug: "a"}], stop: {:failed, %{class: :environment}}}} =
             Drain.run(tmp_dir, hooks(states, outcomes, lines))
  end

  test "a provider failure is recorded and the next Intent still builds", %{tmp_dir: tmp_dir} do
    {:ok, states} = Agent.start_link(fn -> %{"a" => {:approved, 1}, "b" => {:approved, 2}} end)
    failed = %{outcome("a", :failed, :provider) | reason: "timeout"}
    outcomes = %{"a" => failed, "b" => outcome("b", :landed, nil)}
    {:ok, lines} = Agent.start_link(fn -> [] end)

    assert {:ok, %{builds: [^failed, %{slug: "b", status: :landed}], stop: :empty}} =
             Drain.run(tmp_dir, hooks(states, outcomes, lines))

    assert "failed a: provider/timeout (Build run-a)\n" in Agent.get(lines, & &1)
  end

  test "an unavailable provider pauses the drain and builds the same Intent again", %{
    tmp_dir: tmp_dir
  } do
    {:ok, states} = Agent.start_link(fn -> %{"a" => {:approved, 1}, "b" => {:approved, 2}} end)
    limited = %{outcome("a", :failed, :provider) | reason: "usage_limit"}
    {:ok, script} = Agent.start_link(fn -> [limited, outcome("a", :landed, nil)] end)
    {:ok, lines} = Agent.start_link(fn -> [] end)
    test_process = self()

    hooks = %{
      hooks(states, %{"b" => outcome("b", :landed, nil)}, lines)
      | build: fn
          "a" ->
            result = Agent.get_and_update(script, fn [next | rest] -> {next, rest} end)
            Agent.update(states, &Map.put(&1, "a", {result.status, nil}))
            {:ok, result}

          "b" ->
            {:ok, outcome("b", :landed, nil)}
        end
    }

    hooks =
      Map.put(hooks, :pause, fn wait_ms ->
        send(test_process, {:paused, wait_ms})
        :ok
      end)

    assert {:ok, %{builds: builds, stop: :empty}} = Drain.run(tmp_dir, hooks)

    assert Enum.map(builds, &{&1.slug, &1.status}) == [
             {"a", :failed},
             {"a", :landed},
             {"b", :landed}
           ]

    assert_received {:paused, 300_000}

    assert "queue: the provider is unavailable (usage_limit); building a again in 5 min\n" in Agent.get(
             lines,
             & &1
           )
  end

  test "builds an approval at most once per drain even if it stays queued", %{tmp_dir: tmp_dir} do
    {:ok, states} = Agent.start_link(fn -> %{"stuck" => {:approved, 1}} end)
    {:ok, lines} = Agent.start_link(fn -> [] end)

    stuck = %{
      hooks(states, %{}, lines)
      | build: fn slug -> {:ok, outcome(slug, :failed, :candidate)} end
    }

    assert {:ok, %{builds: [%{slug: "stuck"}], stop: :empty}} = Drain.run(tmp_dir, stuck)
  end

  test "a running drain is reported and a stop request ends the next step", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "queue.pid"), System.pid() <> "\n")
    {:ok, states} = Agent.start_link(fn -> %{"a" => {:approved, 1}} end)
    {:ok, lines} = Agent.start_link(fn -> [] end)
    own = String.to_integer(System.pid())

    assert Drain.run(tmp_dir, hooks(states, %{}, lines)) == {:running, own}
    assert Lock.request_stop(tmp_dir) == {:stopping, own}

    File.rm!(Path.join(tmp_dir, "queue.pid"))
    assert Lock.acquire(tmp_dir) == :ok
    File.write!(Path.join(tmp_dir, "queue.stop"), "stop\n")
    assert Lock.stop_requested?(tmp_dir)
    assert Lock.release(tmp_dir) == :ok
    refute File.exists?(Path.join(tmp_dir, "queue.stop"))
  end

  test "a lock left by a dead process is taken over", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "queue.pid"), "999999\n")

    assert Lock.state(tmp_dir) == :stopped
    assert Lock.acquire(tmp_dir) == :ok
    assert File.read!(Path.join(tmp_dir, "queue.pid")) == System.pid() <> "\n"
    assert Lock.release(tmp_dir) == :ok
    assert Lock.request_stop(tmp_dir) == :not_running
  end

  defp hooks(states, outcomes, lines) do
    %{
      recover: fn -> {:ok, []} end,
      statuses: fn -> {:ok, statuses(states)} end,
      build: fn slug ->
        result = Map.fetch!(outcomes, slug)
        Agent.update(states, &Map.put(&1, slug, {result.status, nil}))
        {:ok, result}
      end,
      say: fn line -> Agent.update(lines, &[line | &1]) end
    }
  end

  defp statuses(states) do
    states
    |> Agent.get(& &1)
    |> Enum.map(fn {slug, {status, approved_at}} ->
      %IntentStatus{
        slug: slug,
        status: status,
        run_id: nil,
        landed_sha: nil,
        approved_at: approved_at
      }
    end)
  end

  defp outcome(slug, status, class) do
    %{
      slug: slug,
      status: status,
      run_id: "run-" <> slug,
      landed_sha: if(status == :landed, do: "abcdef1234567890"),
      class: class,
      reason: if(class, do: "gate_red")
    }
  end
end
