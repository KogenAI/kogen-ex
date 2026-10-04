defmodule StateFakeWorkspace do
  @moduledoc false

  @spec initial() :: map()
  def initial do
    %{
      refs: %{},
      objects: %{},
      counter: 0,
      branch_head: "main-0",
      ancestors: MapSet.new(),
      intent_commits: %{}
    }
  end

  @spec ref_read(Agent.agent(), String.t(), map()) :: {:ok, String.t()} | {:error, :missing}
  def ref_read(repo, ref, _git_env) do
    repo
    |> Agent.get(fn state -> Map.fetch(state.refs, ref) end)
    |> case do
      {:ok, sha} -> {:ok, sha}
      :error -> {:error, :missing}
    end
  end

  @spec ref_create(Agent.agent(), String.t(), String.t(), map()) :: :ok | {:error, :exists}
  def ref_create(repo, ref, sha, _git_env) do
    Agent.get_and_update(repo, fn state ->
      if Map.has_key?(state.refs, ref) do
        {{:error, :exists}, state}
      else
        {:ok, put_in(state.refs[ref], sha)}
      end
    end)
  end

  @spec ref_update(Agent.agent(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, :stale}
  def ref_update(repo, ref, new, old, _git_env) do
    Agent.get_and_update(repo, fn state ->
      if Map.get(state.refs, ref) == old do
        {:ok, put_in(state.refs[ref], new)}
      else
        {{:error, :stale}, state}
      end
    end)
  end

  @spec ref_delete(Agent.agent(), String.t(), String.t(), map()) :: :ok | {:error, :stale}
  def ref_delete(repo, ref, expected, _git_env) do
    Agent.get_and_update(repo, fn state ->
      if Map.get(state.refs, ref) == expected do
        {:ok, update_in(state.refs, &Map.delete(&1, ref))}
      else
        {{:error, :stale}, state}
      end
    end)
  end

  @spec commit_tree_with_files(Agent.agent(), map(), [String.t()], String.t(), map()) ::
          {:ok, String.t()}
  def commit_tree_with_files(repo, files, parents, message, _git_env) do
    Agent.get_and_update(repo, fn state ->
      counter = state.counter + 1
      sha = "commit-#{counter}"
      object = %{files: files, parents: parents, message: message}
      {{:ok, sha}, %{state | counter: counter, objects: Map.put(state.objects, sha, object)}}
    end)
  end

  @spec read_file_at(Agent.agent(), String.t(), String.t(), map()) ::
          {:ok, binary()} | {:error, :missing}
  def read_file_at(repo, rev, path, _git_env) do
    Agent.get(repo, fn state ->
      with {:ok, object} <- Map.fetch(state.objects, rev),
           {:ok, contents} <- Map.fetch(object.files, path) do
        {:ok, contents}
      else
        _missing -> {:error, :missing}
      end
    end)
  end

  @spec commit_message(Agent.agent(), String.t(), map()) :: {:ok, String.t()} | {:error, :missing}
  def commit_message(repo, rev, _git_env) do
    Agent.get(repo, fn state ->
      case Map.fetch(state.objects, rev) do
        {:ok, object} -> {:ok, object.message}
        :error -> {:error, :missing}
      end
    end)
  end

  @spec rev_parse(Agent.agent(), String.t(), map()) :: {:ok, String.t()} | {:error, :missing}
  def rev_parse(repo, "refs/heads/main", _git_env) do
    Agent.get(repo, &{:ok, &1.branch_head})
  end

  @spec intent_commit(Agent.agent(), String.t(), String.t(), map()) :: {:ok, String.t() | nil}
  def intent_commit(repo, "main", slug, _git_env) do
    Agent.get(repo, &{:ok, Map.get(&1.intent_commits, slug)})
  end

  @spec land_intent(Agent.agent(), String.t(), String.t()) :: :ok
  def land_intent(repo, slug, sha) do
    Agent.update(repo, &put_in(&1.intent_commits[slug], sha))
  end

  @spec ancestor?(Agent.agent(), String.t(), String.t(), map()) :: boolean() | {:error, term()}
  def ancestor?(repo, ancestor, descendant, _git_env) do
    Agent.get(repo, fn state ->
      ancestor == descendant or MapSet.member?(state.ancestors, {ancestor, descendant})
    end)
  end

  @spec allow_ancestor(Agent.agent(), String.t(), String.t()) :: :ok
  def allow_ancestor(repo, ancestor, descendant) do
    Agent.update(repo, &%{&1 | ancestors: MapSet.put(&1.ancestors, {ancestor, descendant})})
  end
end

defmodule Kogen.State.StateTest do
  use Kogen.Testkit.Case

  alias Kogen.State
  alias Kogen.State.Approval
  alias Kogen.State.Event

  setup do
    repo = start_supervised!({Agent, &StateFakeWorkspace.initial/0})
    {:ok, repo: repo, workspace: StateFakeWorkspace}
  end

  test "approval commits and reconstructs the full immutable package", context do
    approved = approval()

    assert {:ok, approval_commit} =
             State.approve(context.repo, approved, %{}, workspace: context.workspace)

    assert {:ok, loaded} =
             State.approval(context.repo, approved.slug, %{}, workspace: context.workspace)

    assert loaded == approved

    {:ok, stored_ref} =
      StateFakeWorkspace.ref_read(context.repo, "refs/kogen/intents/demo-feature", %{})

    assert stored_ref == approval_commit

    {:ok, intent_bytes} =
      StateFakeWorkspace.read_file_at(
        context.repo,
        approval_commit,
        ".kogen/intents/demo-feature/intent.md",
        %{}
      )

    assert intent_bytes == approved.intent_bytes

    {:ok, acceptance_bytes} =
      StateFakeWorkspace.read_file_at(
        context.repo,
        approval_commit,
        "test/acceptance/demo_feature_test.exs",
        %{}
      )

    assert acceptance_bytes == approved.acceptance_files["test/acceptance/demo_feature_test.exs"]
  end

  test "approval rejects bytes that do not match the approved hash", context do
    approved = %{approval() | intent_bytes: "different bytes"}

    assert {:error, :intent_hash_mismatch} =
             State.approve(context.repo, approved, %{}, workspace: context.workspace)
  end

  test "run metadata uses atomic run.json and appends one JSON object per event", context do
    assert {:ok, run} = State.start_run(context.tmp_dir, approval())
    assert File.dir?(Path.join(run.dir, "transcripts"))
    assert File.dir?(Path.join(run.dir, "logs"))

    run_json = Path.join(run.dir, "run.json")
    assert {:ok, json} = File.read(run_json)
    assert %{"run_id" => run_id, "status" => "running"} = :json.decode(json)
    assert run_id == run.id
    assert Enum.all?(File.ls!(run.dir), &(not String.ends_with?(&1, ".tmp")))

    assert :ok = State.record(run, %{event: :stage, stage: :check})
    assert :ok = State.record(run, %{event: :finished, status: :failed, reason: :red})

    events =
      run.dir |> Path.join("events.jsonl") |> File.read!() |> String.split("\n", trim: true)

    assert length(events) == 2
    assert Enum.all?(events, &is_map(:json.decode(&1)))

    assert {:ok, loaded} = State.load(context.tmp_dir, run.id)
    assert loaded.status == :failed
    assert {:ok, [listed]} = State.list(context.tmp_dir)
    assert listed.id == run.id
  end

  test "landing identity is durable before landing and includes the run id", context do
    {:ok, run} = State.start_run(context.tmp_dir, approval())

    assert :ok = State.record(run, %{event: :landing_prepared, landing: landing_identity(run)})
    assert {:ok, loaded} = State.load(context.tmp_dir, run.id)

    assert loaded.landing.approval_commit == "approval-commit"
    assert loaded.landing.run_id == run.id
    assert loaded.landing.expected_parent == "base-sha"
    assert loaded.landing.final_tree == "tree-sha"
    assert loaded.landing.candidate_commit == "candidate-sha"
  end

  test "project-wide claim is create-only and release compares the claim value", context do
    assert :ok = State.claim(context.repo, "run-a", %{}, workspace: context.workspace)

    assert {:error, {:claimed, "run-a"}} =
             State.claim(context.repo, "run-b", %{}, workspace: context.workspace)

    assert {:error, :not_owner} =
             State.release(context.repo, "run-b", %{}, workspace: context.workspace)

    assert :ok = State.release(context.repo, "run-a", %{}, workspace: context.workspace)
    assert :ok = State.claim(context.repo, "run-b", %{}, workspace: context.workspace)
  end

  test "status is derived from approval, claim, terminal run and base trailer",
       context do
    approved = approval()
    assert_status(context, approved.slug, :draft)

    assert {:ok, approval_commit} =
             State.approve(context.repo, approved, %{}, workspace: context.workspace)

    assert_status(context, approved.slug, :approved)

    other = %{approved | slug: "other-feature"}

    assert {:ok, _other_commit} =
             State.approve(context.repo, other, %{}, workspace: context.workspace)

    {:ok, building_run} = State.start_run(context.tmp_dir, approved)
    assert :ok = State.claim(context.repo, building_run.id, %{}, workspace: context.workspace)
    assert_status(context, approved.slug, :building)
    assert_status(context, other.slug, :approved)
    assert :ok = State.release(context.repo, building_run.id, %{}, workspace: context.workspace)

    record_terminal_run(context, approved, approval_commit, :failed, :red)
    assert_status(context, approved.slug, :failed)

    record_terminal_run(context, approved, approval_commit, :parked, :base_moved)
    assert_status(context, approved.slug, :parked)

    {:ok, landed_run} = State.start_run(context.tmp_dir, approved)
    assert :ok = State.record(landed_run, %{approval_commit: approval_commit})
    assert :ok = State.put_landing(landed_run, Map.delete(landing_identity(landed_run), :run_id))
    assert :ok = StateFakeWorkspace.allow_ancestor(context.repo, "candidate-sha", "main-0")
    assert :ok = StateFakeWorkspace.land_intent(context.repo, approved.slug, "candidate-sha")
    assert_status(context, approved.slug, :landed)
  end

  test "journal decoding keeps verification result separate from lifecycle status" do
    assert {:ok, %Event{event: "check_result", status: nil, result: "pass"}} =
             State.decode_event(~s({"event":"check_result","result":"pass"}))
  end

  test "journal decoding preserves model stage wall time" do
    assert {:ok, %Event{event: "model_stage", stage: "shape", wall_ms: 37}} =
             State.decode_event(~s({"event":"model_stage","stage":"shape","wall_ms":37}))
  end

  test "journal decoding retains build credential provenance for reports" do
    assert {:ok,
            %Event{
              event: "started",
              credential_source: "kogen_owned",
              credential_label: "personal"
            }} =
             State.decode_event(
               ~s({"event":"started","credential_source":"kogen_owned","credential_label":"personal"})
             )
  end

  test "journal decoding retains the selected build recipe" do
    assert {:ok, %Event{event: "started", recipe: "direct"}} =
             State.decode_event(~s({"event":"started","recipe":"direct"}))
  end

  test "journal decoding preserves phase timing event fields" do
    assert {:ok,
            %Event{
              event: "phase_timing",
              phase: "build",
              name: "gate_run",
              wall_ms: 37,
              started_at: 1_700,
              finished_at: 1_737
            }} =
             State.decode_event(
               ~s({"event":"phase_timing","phase":"build","name":"gate_run","wall_ms":37,"started_at":1700,"finished_at":1737})
             )
  end

  test "journal decoding preserves scope warnings and excused test seeds" do
    assert {:ok,
            %Event{
              event: "scope_warning",
              path: "README.md",
              declared_domains: ["kernel"],
              detail: "out of scope"
            }} =
             State.decode_event(
               ~s({"event":"scope_warning","path":"README.md","declared_domains":["kernel"],"detail":"out of scope"})
             )

    assert {:ok, %Event{event: "flake_excused", test_ids: ["test/foo_test.exs:12"], seed: 17}} =
             State.decode_event(
               ~s({"event":"flake_excused","test_ids":["test/foo_test.exs:12"],"seed":17})
             )
  end

  test "reconcile records a landing after CAS and releases only its own claim", context do
    approved = approval()

    {:ok, approval_commit} =
      State.approve(context.repo, approved, %{}, workspace: context.workspace)

    {:ok, run} = State.start_run(context.tmp_dir, approved)

    assert :ok = State.record(run, %{approval_commit: approval_commit})
    assert :ok = State.put_landing(run, Map.delete(landing_identity(run), :run_id))
    assert :ok = State.claim(context.repo, run.id, %{}, workspace: context.workspace)
    assert :ok = StateFakeWorkspace.allow_ancestor(context.repo, "candidate-sha", "main-0")

    assert {:ok, :landed} =
             State.reconcile(context.repo, context.tmp_dir, run, "main", %{},
               workspace: context.workspace
             )

    assert :ok = StateFakeWorkspace.land_intent(context.repo, approved.slug, "candidate-sha")

    assert State.status(context.repo, context.tmp_dir, approved.slug, "main", %{},
             workspace: context.workspace
           ) == :landed

    assert {:error, :missing} = StateFakeWorkspace.ref_read(context.repo, "refs/kogen/claim", %{})
  end

  defp approval do
    bytes = "# Demo feature\n"
    {:ok, at, 0} = DateTime.from_iso8601("2026-10-02T10:15:30Z")

    %Approval{
      slug: "demo-feature",
      intent_bytes: bytes,
      intent_sha256: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
      target_branch: "main",
      base_sha: "base-sha",
      domains: ["lib/kogen/state"],
      acceptance_files: %{
        "test/acceptance/demo_feature_test.exs" => "defmodule DemoAcceptance do\nend\n"
      },
      protected_manifest: %{"mix.exs" => String.duplicate("a", 64)},
      by: "Almir",
      at: at
    }
  end

  defp landing_identity(run) do
    %{
      approval_commit: "approval-commit",
      run_id: run.id,
      expected_parent: "base-sha",
      final_tree: "tree-sha",
      candidate_commit: "candidate-sha"
    }
  end

  defp assert_status(context, slug, expected) do
    assert State.status(context.repo, context.tmp_dir, slug, "main", %{},
             workspace: context.workspace
           ) == expected
  end

  defp record_terminal_run(context, approved, approval_commit, status, reason) do
    {:ok, run} = State.start_run(context.tmp_dir, approved)
    assert :ok = State.record(run, %{approval_commit: approval_commit})
    assert :ok = State.record(run, %{event: :finished, status: status, reason: reason})
  end
end
