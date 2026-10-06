defmodule Kogen.Harness.PlanBudgetTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.HarnessScriptedProvider, as: ScriptedProvider

  @constraint "Preserve the exact ready value and the public function name."
  @intent "Change README.md to ready.\n## Acceptance\n- A1: README.md contains ready.\n## Request\n" <>
            @constraint

  test "oversized plans are shortened without dropping Intent constraints or changing models", %{
    tmp_dir: tmp
  } do
    provider =
      ScriptedProvider.start([
        answer(String.duplicate("évidence ", 600)),
        answer(plan()),
        call("shell", %{"cmd" => "printf 'ready\\n' > README.md"}, "patch"),
        call("finish", %{}, "finish")
      ])

    opts = options(tmp, provider)
    assert {:ok, advisory} = Harness.plan(opts, nil, @intent)
    assert advisory.text == plan()
    assert advisory.usage.output == 20
    assert {:ok, %{outcome: :done}} = Harness.develop(opts, @intent, advisory, nil)
    assert File.read!(Path.join(opts.workdir, "README.md")) == "ready\n"

    attempts = opts |> records() |> Enum.filter(&is_integer(&1["started_at"]))
    plans = Enum.filter(attempts, &(&1["stage"] == "plan"))
    assert Enum.map(plans, & &1["plan_budget_status"]) == ["over_budget", "within_budget"]
    assert hd(plans)["plan_output_bytes"] == byte_size(String.duplicate("évidence ", 600))
    assert List.last(plans)["plan_step_count"] == 3
    assert Enum.all?(plans, &(&1["model"] == "gpt-6.1-sol" and &1["effort"] == "high"))

    builder = Enum.find(attempts, &(&1["stage"] == "develop"))
    assert builder["intent_bytes"] == byte_size(@intent)
    assert builder["plan_bytes"] == byte_size(plan())
    assert builder["plan_injection_bytes"] == byte_size(advisory.builder_addendum)
    assert builder["plan_injection_words"] <= builder["plan_max_words"]
    assert builder["planner_policy"] == "concise-ls-files-v1"

    [first, shortened, build | _rest] = ScriptedProvider.requests(provider)
    assert first.tools == [] and shortened.tools == []
    assert {first.model, first.effort} == {shortened.model, shortened.effort}
    assert {build.model, build.effort} == {"gpt-6-luna", "max"}
    text = build.input |> hd() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
    assert length(String.split(text, @constraint)) == 2
    assert text =~ "planner did not read file contents"
    refute text =~ "investigating a scratch copy"
  end

  test "an explicit larger budget accepts a fuller difficult plan unchanged", %{tmp_dir: tmp} do
    text = "Difficulty: hard\n" <> plan() <> String.duplicate("Detailed assumption. ", 300)
    provider = ScriptedProvider.start([answer(text)])
    opts = %{options(tmp, provider) | plan_max_words: 800, planner_difficulty: true}
    assert {:ok, advisory} = Harness.plan(opts, nil, @intent)
    assert advisory.text == text
    assert [row] = records(opts)
    assert row["plan_max_words"] == 800
    assert row["plan_injection_words"] > 500
    assert row["plan_injection_words"] <= 800
    assert row["plan_budget_status"] == "within_budget"
    assert row["planner_context"] == "intent_and_file_names"
    assert row["model"] == "gpt-6.1-sol"
    assert row["effort"] == "high"
  end

  test "three oversized responses fail visibly instead of injecting a truncated plan", %{
    tmp_dir: tmp
  } do
    provider = ScriptedProvider.start(List.duplicate(answer(String.duplicate("large ", 600)), 3))
    opts = options(tmp, provider)

    assert {:error, %{reason: :plan_word_budget_exceeded, detail: detail}} =
             Harness.plan(opts, nil, @intent)

    assert detail =~ "no plan was injected"
    assert length(records(opts)) == 3
    assert Enum.all?(records(opts), &(&1["plan_budget_status"] == "over_budget"))
    assert length(ScriptedProvider.requests(provider)) == 3
  end

  defp options(tmp, provider) do
    workdir = Git.create!(Path.join(tmp, "repo"))

    %Opts{
      workdir: workdir,
      run_dir: Path.join(tmp, "run"),
      project: %Project{
        root: workdir,
        name: "budget",
        checks: [
          %CheckSpec{name: "ready", argv: ["grep", "-qx", "ready", "README.md"], timeout_ms: 5000}
        ],
        setup: [],
        fix: [],
        diagnose: [],
        protected_paths: [],
        domains: %{"harness" => ["README.md"]}
      },
      provider_mod: ScriptedProvider,
      provider_config: provider,
      proc_mod: Kogen.Proc,
      env: %{},
      planner_mode: :ls_files,
      builder_tools: :shell,
      changed?: fn -> {:ok, File.read!(Path.join(workdir, "README.md")) == "ready\n"} end,
      limits: %{max_turns: 10, wall_ms: 60_000}
    }
  end

  defp plan do
    "## Implementation steps\n1. Inspect README.md for A1.\n2. Make the coherent A1 change.\n3. Inspect the result.\n## Risks and API checks\n- Confirm the existing format.\n## Targeted verification\nRun grep -qx ready README.md; expect exit 0."
  end

  defp records(opts),
    do:
      opts.run_dir
      |> Path.join("requests.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)

  defp answer(text),
    do: %ModelResponse{
      id: "plan",
      text: text,
      tool_calls: [],
      usage: %{output: 10},
      raw_items: [
        %{"role" => "assistant", "content" => [%{"type" => "output_text", "text" => text}]}
      ]
    }

  defp call(name, arguments, id),
    do: %ModelResponse{
      id: id,
      text: "",
      usage: %{},
      tool_calls: [%ToolCall{id: id, name: name, arguments: arguments}],
      raw_items: [
        %{"type" => "function_call", "call_id" => id, "name" => name, "arguments" => arguments}
      ]
    }
end
