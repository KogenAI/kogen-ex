defmodule Kogen.Kernel.CheckProposalTest do
  use Kogen.Testkit.Case, async: true

  import ExUnit.CaptureIO

  alias Kogen.Contracts.Failure
  alias Kogen.State
  alias Kogen.State.Approval
  alias Kogen.Testkit.Git
  alias Mix.Tasks.Kogen.Checks.Effect
  alias Mix.Tasks.Kogen.Checks.Sample

  test "recurring failures retain examples, cost and separate package destinations", %{
    tmp_dir: root
  } do
    {run, context} = fixture!(root)

    assert :ok =
             State.record(run, %{
               event: :model_stage,
               stage: :develop,
               model: "gpt-6-luna",
               wall_ms: 17
             })

    assert :ok =
             observe(run, context, "quality: public API has an unchecked result at lib/bad.ex:12")

    [path] = proposal_paths(root)
    assert JSON.decode!(File.read!(path))["status"] == "watching"

    assert :ok =
             observe(run, context, "quality: public API has an unchecked result at lib/bad.ex:12")

    assert length(JSON.decode!(File.read!(path))["observations"]) == 1

    assert :ok =
             observe(
               run,
               %{context | repairs_left: 1},
               "quality: public API has an unchecked result at lib/bad.ex:28"
             )

    proposal = JSON.decode!(File.read!(path))
    assert proposal["status"] == "candidate"
    assert proposal["target"] == "kogen_credo"
    assert proposal["blocking"] == false
    assert proposal["planted_bad_example"] != []
    assert proposal["valid_contrasting_examples"] != []
    assert hd(proposal["measured_build_effect"]["samples"])["model_wall_ms"] == 17
    assert :ok = observe(run, context, "style: prefer explicit result names")
    assert :ok = observe(run, %{context | repairs_left: 1}, "style: prefer explicit result names")
    destinations = for file <- proposal_paths(root), do: JSON.decode!(File.read!(file))["target"]
    assert Enum.sort(destinations) == ["kogen_credo", "optimum_credo"]
    assert File.read!(Path.join(run.dir, "events.jsonl")) =~ "check_proposal_drafted"
  end

  test "developer tooling records real precision before drafting a separately approved adoption Intent",
       %{
         tmp_dir: root
       } do
    {_run, context, proposal} = recurring!(root)
    spec = spec!(root, context.workdir, false)

    assert {0, output} =
             task_output(Sample, [proposal, spec, "--project", context.workdir])

    assert output =~ "Caller must shape and approve this individual protected rule"
    [report] = Path.wildcard(Path.join(Path.dirname(proposal), "sample-*/qualification.json"))
    result = JSON.decode!(File.read!(report))
    assert result["metrics"]["precision"] == 1.0
    assert result["metrics"]["real_cases"] == 3
    assert result["metrics"]["true_positives"] == 1
    assert result["adoption_ready"] == true
    assert result["blocking"] == false
    assert result["measured_build_effect"]["checker_wall_ms"] > 0
    assert length(result["precision_sample"]) == 6
    assert File.exists?(Path.join(Path.dirname(report), "adoption-intent.md"))
    refute File.exists?(Path.join(context.workdir, ".credo.exs"))
    refute File.exists?(Path.join(context.workdir, "checker-relative-write.txt"))

    assert File.exists?(
             Path.join(Path.dirname(report), "checker-workspace/checker-relative-write.txt")
           )
  end

  test "false positives keep the sample and prohibit an adoption draft", %{tmp_dir: root} do
    {_run, context, proposal} = recurring!(root)
    spec = spec!(root, context.workdir, true)

    assert {0, output} =
             task_output(Sample, [proposal, spec, "--project", context.workdir])

    assert output =~ "need more work before proposing adoption"
    [report] = Path.wildcard(Path.join(Path.dirname(proposal), "sample-*/qualification.json"))
    result = JSON.decode!(File.read!(report))
    assert result["metrics"]["false_positives"] == 2
    assert result["metrics"]["precision"] < 0.9
    refute File.exists?(Path.join(Path.dirname(report), "adoption-intent.md"))
    assert result["blocking"] == false
  end

  test "unsafe and insufficient real-code samples fail with readable feedback", %{tmp_dir: root} do
    {_run, context, proposal} = recurring!(root)
    path = spec!(root, context.workdir, false)
    spec = JSON.decode!(File.read!(path))

    File.write!(
      path,
      JSON.encode!(Map.put(spec, "real_examples", [%{path: "../outside.ex", expected: "bad"}]))
    )

    assert {1, output} =
             task_output(Sample, [proposal, path, "--project", context.workdir])

    assert output =~ "invalid_precision_spec"
    assert Path.wildcard(Path.join(Path.dirname(proposal), "sample-*/adoption-intent.md")) == []
  end

  test "checker errors retain evidence and cannot qualify a protected rule", %{tmp_dir: root} do
    {_run, context, proposal} = recurring!(root)
    path = spec!(root, context.workdir, false)
    spec = JSON.decode!(File.read!(path))
    File.write!(path, JSON.encode!(Map.put(spec, "argv", ["sh", "-c", "exit 127", "{path}"])))

    assert {0, output} =
             task_output(Sample, [proposal, path, "--project", context.workdir])

    assert output =~ "need more work"
    [report] = Path.wildcard(Path.join(Path.dirname(proposal), "sample-*/qualification.json"))
    result = JSON.decode!(File.read!(report))
    assert result["metrics"]["errors"] == 6
    assert result["adoption_ready"] == false
    refute File.exists?(Path.join(Path.dirname(report), "adoption-intent.md"))
  end

  test "later Build comparisons remain hash-bound to the precision evidence", %{tmp_dir: root} do
    {before, context, proposal} = recurring!(root)
    spec = spec!(root, context.workdir, false)

    assert {0, _output} =
             task_output(Sample, [proposal, spec, "--project", context.workdir])

    [report] = Path.wildcard(Path.join(Path.dirname(proposal), "sample-*/qualification.json"))

    {:ok, next} =
      State.start_run(Path.join(root, "state"), %Approval{
        slug: "learning",
        intent_bytes: "request",
        intent_sha256: hash("request"),
        target_branch: "main",
        base_sha: context.base_sha,
        domains: [],
        acceptance_files: %{},
        protected_manifest: %{},
        by: "test",
        at: ~U[2026-10-06 00:00:00Z]
      })

    assert :ok = State.record(before, %{event: :model_stage, model: "gpt-6-luna", wall_ms: 100})
    assert :ok = State.record(before, %{event: :repair})
    assert :ok = State.record(before, %{event: :finished, status: :failed})
    assert :ok = State.record(next, %{event: :model_stage, model: "gpt-6-luna", wall_ms: 70})
    assert :ok = State.record(next, %{event: :finished, status: :failed})

    assert {0, output} =
             task_output(Effect, [report, before.dir, next.dir])

    assert output =~ "Measured Build comparison:"
    [effect] = Path.wildcard(Path.join(Path.dirname(report), "build-effect-*.json"))
    data = JSON.decode!(File.read!(effect))
    assert data["model_wall_ms_delta"] == -30
    assert data["repair_delta"] == -1
    assert data["qualification_sha256"] == hash(File.read!(report))
    assert data["interpretation"] =~ "not a causal benefit claim"
  end

  test "developer tools reject incomplete arguments" do
    assert {1, output} = task_output(Sample, ["proposal.json", "--bogus"])
    assert output =~ "Usage: mix kogen.checks.sample"
    assert {1, output} = task_output(Effect, ["qualification.json"])
    assert output =~ "Usage: mix kogen.checks.effect"
  end

  defp task_output(task, args) do
    caller = self()

    output =
      capture_io(fn ->
        try do
          task.run(args)
          send(caller, {:task_status, 0})
        rescue
          error in Mix.Error ->
            IO.puts(Exception.message(error))
            send(caller, {:task_status, 1})
        end
      end)

    assert_receive {:task_status, status}
    {status, output}
  end

  defp fixture!(root) do
    repo = Git.create!(Path.join(root, "project"))
    write!(repo, "lib/bad.ex", source(:checked, "Example"))
    Git.git!(repo, ["add", "--all"])
    Git.git!(repo, ["commit", "--quiet", "-m", "Seed real examples"])
    base = repo |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()
    write!(repo, "lib/bad.ex", source(:unchecked, "Example"))

    approval = %Approval{
      slug: "learning",
      intent_bytes: "request",
      intent_sha256: hash("request"),
      target_branch: "main",
      base_sha: base,
      domains: [],
      acceptance_files: %{},
      protected_manifest: %{},
      by: "test",
      at: ~U[2026-10-06 00:00:00Z]
    }

    {:ok, run} = State.start_run(Path.join(root, "state"), approval)

    context = %{
      workdir: repo,
      base_sha: base,
      git_env: Git.env(),
      model: "gpt-6-luna",
      attempt: :builder,
      repairs_left: 2,
      stage: :review
    }

    {run, context}
  end

  defp recurring!(root) do
    {run, context} = fixture!(root)
    assert :ok = observe(run, context, "quality: public API has an unchecked result")

    assert :ok =
             observe(
               run,
               %{context | repairs_left: 1},
               "quality: public API has an unchecked result"
             )

    [path] = proposal_paths(root)
    {run, context, path}
  end

  defp observe(run, context, detail),
    do:
      Kogen.CheckLearning.observe(run, context, %Failure{
        class: :candidate,
        reason: :review_revise,
        detail: detail
      })

  defp proposal_paths(root),
    do: Path.wildcard(Path.join(root, "state/check-proposals/*/proposal.json"))

  defp spec!(root, repo, noisy?) do
    write!(repo, "lib/valid.ex", source(:checked, "Valid"))
    write!(repo, "lib/contrast.ex", source(:other_valid_result, "Contrast"))

    checker = """
    File.write!("checker-relative-write.txt", "sample only")
    {:ok, ast} = Code.string_to_quoted(File.read!(hd(System.argv())))
    {_, bad?} = Macro.prewalk(ast, false, fn
      :unchecked, _acc -> {:unchecked, true}
      node, acc -> {node, acc}
    end)
    bad? = bad? or #{noisy?}
    if bad?, do: IO.puts("unchecked public result")
    System.halt(if(bad?, do: 1, else: 0))
    """

    write!(repo, "checker.exs", checker)

    spec = %{
      argv: [System.find_executable("elixir"), "--erl", "+S 1:1 +A 1", "checker.exs", "{path}"],
      rule_path: "checker.exs",
      feedback: "unchecked public result",
      planted_bad: source(:unchecked, "Planted"),
      valid_examples: [source(:checked, "ControlOne"), source(:other_valid_result, "ControlTwo")],
      real_examples: [
        %{path: "lib/bad.ex", expected: "bad"},
        %{path: "lib/valid.ex", expected: "valid"},
        %{path: "lib/contrast.ex", expected: "valid"}
      ]
    }

    path = Path.join(root, "sample.json")
    File.write!(path, JSON.encode!(spec))
    path
  end

  defp source(value, module), do: "defmodule #{module} do\n  def run, do: :#{value}\nend\n"
  defp hash(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp write!(root, path, bytes) do
    destination = Path.join(root, path)
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, bytes)
  end
end
