defmodule Kogen.State.FlakeWorkflowTest do
  use Kogen.Testkit.Case

  alias Kogen.State
  alias Kogen.State.Approval

  test "recurrence uses distinct Builds, drafts a fix and preserves caller edits without approving",
       %{tmp_dir: tmp} do
    {:ok, first} = State.start_run(tmp, approval())
    record_flake(first, "base_flake", 17)
    record_flake(first, "base_flake", 18)
    assert Path.wildcard(Path.join(tmp, "flake-fixes/*/intent.md")) == []
    {:ok, second} = State.start_run(tmp, approval())
    record_flake(second, "base_flake", 19)
    assert [path] = Path.wildcard(Path.join(tmp, "flake-fixes/*/intent.md"))
    assert {:ok, intent} = Kogen.Testkit.IntentFixture.parse(File.read!(path), path)
    assert length(intent.acceptance) == 2
    assert intent.domains == ["state"]
    [draft] = Enum.filter(events(second), &(&1.event == "flake_fix_drafted"))
    assert draft.detail["approved"] == false
    assert draft.detail["builds"] == 2
    metrics = Enum.find(Enum.reverse(events(second)), &(&1.event == "flake_metrics")).metrics
    assert metrics["retry_cost_ms"] == 126
    assert metrics["leaked_candidate_flakes"] == 0
    assert metrics["recurrence"] == [%{"test_id" => "test/flaky_test.exs:12", "builds" => 2}]
    assert metrics["history_complete"]
    File.write!(path, File.read!(path) <> "\nCaller repair notes.\n")
    {:ok, third} = State.start_run(tmp, approval())
    record_flake(third, "base_flake", 20)
    assert File.read!(path) =~ "Caller repair notes."

    evidence =
      path |> Path.dirname() |> Path.join("evidence.json") |> File.read!() |> JSON.decode!()

    assert length(evidence["builds"]) == 3
    assert length(evidence["observations"]) == 4
    assert {:ok, %{status: :running}} = State.load(tmp, third.id)
  end

  test "rejected Candidate flakes and historical leaks are measured without new queue policy", %{
    tmp_dir: tmp
  } do
    {:ok, run} = State.start_run(tmp, approval())
    record_flake(run, "candidate_flake", 8)
    assert Path.wildcard(Path.join(tmp, "flake-fixes/*/intent.md")) == []
    metrics = Enum.find(Enum.reverse(events(run)), &(&1.event == "flake_metrics")).metrics
    assert metrics["candidate_flakes"] == 1
    # Inject a historical erroneous receipt to verify the leak metric rather than hiding it.
    assert :ok =
             State.record(run, %{
               event: :flake_excused,
               test_ids: ["test/flaky_test.exs:12"],
               seed: 8,
               detail:
                 "candidate_flake"
                 |> evidence(8)
                 |> Map.put(:excused_test_ids, ["test/flaky_test.exs:12"])
             })

    metrics = Enum.find(Enum.reverse(events(run)), &(&1.event == "flake_metrics")).metrics
    assert metrics["leaked_candidate_flakes"] == 1
    assert metrics["retry_cost_ms"] == 42
    assert metrics["policy"] =~ "no queue-stop rate selected"
    assert {:ok, %{status: :running}} = State.load(tmp, run.id)
  end

  test "a fix draft failure is named and leaves the started Build running", %{tmp_dir: tmp} do
    {:ok, first} = State.start_run(tmp, approval())
    record_flake(first, "base_flake", 11)
    File.write!(Path.join(tmp, "flake-fixes"), "blocked directory")
    {:ok, second} = State.start_run(tmp, approval())
    record_flake(second, "base_flake", 12)
    assert Enum.any?(events(second), &(&1.event == "flake_fix_failed"))
    assert {:ok, %{status: :running}} = State.load(tmp, second.id)
  end

  test "old excusals without evidence remain visible and are not counted as measured leaks", %{
    tmp_dir: tmp
  } do
    {:ok, run} = State.start_run(tmp, approval())

    assert :ok =
             State.record(run, %{
               event: :flake_excused,
               test_ids: ["test/legacy_test.exs:5"],
               seed: 3
             })

    metrics = Enum.find(Enum.reverse(events(run)), &(&1.event == "flake_metrics")).metrics
    assert metrics["legacy_excusal_without_evidence"] == 1
    assert metrics["leaked_candidate_flakes"] == 0
    assert Path.wildcard(Path.join(tmp, "flake-fixes/*/intent.md")) == []
  end

  defp record_flake(run, classification, seed) do
    data = evidence(classification, seed)

    assert :ok =
             State.record(run, %{
               event: :flake_classified,
               test_ids: ["test/flaky_test.exs:12"],
               seed: seed,
               detail: data
             })

    if classification == "base_flake" do
      assert :ok =
               State.record(run, %{
                 event: :flake_excused,
                 test_ids: ["test/flaky_test.exs:12"],
                 seed: seed,
                 detail: data
               })
    end
  end

  defp evidence(classification, seed) do
    ids = ["test/flaky_test.exs:12"]
    base? = classification == "base_flake"

    %{
      classification: classification,
      retry_cost_ms: 42,
      domains: ["state"],
      excused_test_ids: if(base?, do: ids, else: []),
      base_failed_test_ids: if(base?, do: ids, else: []),
      candidate_failed_test_ids: if(base?, do: [], else: ids),
      base_sha: String.duplicate("a", 40),
      seed: seed,
      candidate: %{exit_status: 1, argv: ["mix", "test", "--seed", to_string(seed)]},
      candidate_retry: %{exit_status: 0},
      base: %{
        exit_status: if(base?, do: 1, else: 0),
        argv: ["mix", "test" | ids] ++ ["--seed", to_string(seed)]
      }
    }
  end

  defp events(run) do
    run.dir
    |> Path.join("events.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      {:ok, event} = State.decode_event(line)
      event
    end)
  end

  defp approval do
    bytes = "Repair fixture.\n"

    %Approval{
      slug: "flake-fixture",
      intent_bytes: bytes,
      intent_sha256: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
      target_branch: "main",
      base_sha: String.duplicate("a", 40),
      domains: ["state"],
      acceptance_files: %{"test/acceptance/flake-fixture_test.exs" => "fixture"},
      protected_manifest: %{},
      by: "Test",
      at: ~U[2026-10-06 00:00:00Z]
    }
  end
end
