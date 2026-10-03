defmodule Kogen.Harness.ScriptedProvider do
  @moduledoc false
  @behaviour Kogen.Contracts.ProviderPort

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError

  @spec start([term()]) :: pid()
  def start(responses) do
    {:ok, pid} = Agent.start_link(fn -> %{responses: responses, requests: []} end)
    pid
  end

  @impl true
  @spec respond(pid(), ModelRequest.t()) ::
          {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
  def respond(pid, %ModelRequest{} = request) do
    Agent.get_and_update(pid, fn state ->
      case state.responses do
        [response | rest] ->
          {provider_result(response),
           %{state | responses: rest, requests: [request | state.requests]}}

        [] ->
          error = %ProviderError{
            class: :malformed,
            message: "Scripted provider ran out of responses."
          }

          {{:error, error}, %{state | requests: [request | state.requests]}}
      end
    end)
  end

  @spec requests(pid()) :: [ModelRequest.t()]
  def requests(pid), do: Agent.get(pid, &Enum.reverse(&1.requests))

  defp provider_result({:ok, %ModelResponse{}} = result), do: result
  defp provider_result({:error, %ProviderError{}} = result), do: result
  defp provider_result(%ModelResponse{} = response), do: {:ok, response}
end

defmodule Kogen.Harness.Tests do
  @moduledoc false
  use Kogen.Testkit.Case

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Plan
  alias Kogen.Harness.Review
  alias Kogen.Harness.ScriptedProvider

  @intent """
  ---
  title: Harness fixture
  size: small
  domains: [harness]
  ---
  Add the requested implementation.

  ## Acceptance
  - A1: The implementation matches the requested behavior.

  ## Verify
  - A1: test
  """

  test "Developer edits through a tool and finishes at a green gate", %{tmp_dir: tmp_dir} do
    provider = ScriptedProvider.start([edit_call("fixture", "built"), message("Done.")])
    opts = options(tmp_dir, provider)

    assert {:ok, result} = Harness.develop(opts, @intent, nil, nil)
    assert result.outcome == :done
    assert result.turns == 2
    assert File.read!(Path.join(opts.workdir, "README.md")) == "built\n"
    assert result.gate.status == :pass

    transcript = File.read!(result.transcript_path)
    assert transcript =~ "tool_call"
    assert transcript =~ "tool_result"
    assert transcript =~ "function_call_output"
  end

  test "read rejects lexical and symlink escapes from the worktree", %{tmp_dir: tmp_dir} do
    provider =
      ScriptedProvider.start([
        tool_call("read", %{"path" => "../secret.txt"}, "escape-parent"),
        tool_call("read", %{"path" => "leak.txt"}, "escape-link"),
        edit_call("fixture", "safe"),
        message("Done.")
      ])

    opts = options(tmp_dir, provider)
    outside = Path.join(tmp_dir, "outside.txt")
    File.write!(outside, "private\n")
    File.ln_s!(outside, Path.join(opts.workdir, "leak.txt"))

    assert {:ok, result} = Harness.develop(opts, @intent, nil, nil)
    assert result.outcome == :done

    requests = ScriptedProvider.requests(provider)
    replayed = Enum.map_join(requests, "\n", &inspect(&1.input))
    assert replayed =~ "Path escapes the worktree"
    refute replayed =~ "private"
  end

  test "edit reports zero and duplicate matches before a unique edit", %{tmp_dir: tmp_dir} do
    provider =
      ScriptedProvider.start([
        tool_call("edit", edit_args("README.md", "absent", "x"), "zero"),
        tool_call("edit", edit_args("duplicates.txt", "dup", "x"), "many"),
        edit_call("fixture", "changed"),
        message("Done.")
      ])

    opts = options(tmp_dir, provider)
    File.write!(Path.join(opts.workdir, "duplicates.txt"), "dup dup\n")

    assert {:ok, result} = Harness.develop(opts, @intent, nil, nil)
    assert result.outcome == :done
    assert File.read!(Path.join(opts.workdir, "README.md")) == "changed\n"

    tool_inputs =
      provider |> ScriptedProvider.requests() |> Enum.map_join("\n", &inspect(&1.input))

    assert tool_inputs =~ "matched 0 times"
    assert tool_inputs =~ "matched 2 times"
  end

  test "one red gate is returned and the Cycle can resume the same items to green", %{
    tmp_dir: tmp_dir
  } do
    ready_check = %CheckSpec{
      name: "ready-marker",
      argv: ["sh", "-c", "grep -q ready README.md"],
      timeout_ms: 5_000
    }

    provider =
      ScriptedProvider.start([
        edit_call("fixture", "attempt"),
        message("I am done."),
        edit_call("attempt", "ready"),
        message("Fixed and done.")
      ])

    opts = options(tmp_dir, provider, [ready_check])
    assert {:ok, red} = Harness.develop(opts, @intent, nil, nil, 2)
    assert red.outcome == :gate_red
    assert hd(red.gate.failures) =~ "ready-marker"

    repair_opts = %{opts | repairs_left: 1}
    resume = %{previous_items: red.items, failure_text: Enum.join(red.gate.failures, "\n")}
    assert {:ok, fixed} = Harness.develop(repair_opts, @intent, nil, resume, 1)
    assert fixed.outcome == :done
    assert fixed.gate.status == :pass
    assert File.read!(Path.join(opts.workdir, "README.md")) == "ready\n"
    assert fixed.turns == 2
  end

  test "the first empty done claim is refused in the same session", %{tmp_dir: tmp_dir} do
    provider =
      ScriptedProvider.start([
        message("Done without edits."),
        edit_call("fixture", "done"),
        message("Done.")
      ])

    opts = options(tmp_dir, provider)
    opts = %{opts | changed?: fn -> {:ok, false} end}

    assert {:ok, result} = Harness.develop(opts, @intent, nil, nil)
    assert result.outcome == :done
    assert result.turns == 3

    requests = ScriptedProvider.requests(provider)

    assert Enum.any?(
             requests,
             &String.contains?(inspect(&1.input), "Kogen found no changed files")
           )
  end

  test "turn cap returns gave_up after the final allowed tool turn", %{tmp_dir: tmp_dir} do
    provider = ScriptedProvider.start([edit_call("fixture", "at-cap")])
    opts = options(tmp_dir, provider)
    opts = %{opts | limits: %{max_turns: 1, wall_ms: 10_000}}

    assert {:ok, result} = Harness.develop(opts, @intent, nil, nil)
    assert result.outcome == :gave_up
    assert result.turns == 1
    assert File.read!(Path.join(opts.workdir, "README.md")) == "at-cap\n"
  end

  test "context pack, plan, build, and review accept use their fixed models and tools", %{
    tmp_dir: tmp_dir
  } do
    provider =
      ScriptedProvider.start([
        read_call("README.md"),
        message("README.md summarizes this fixture. Kogen.Harness.run/4 coordinates the work."),
        message(
          "1. Update README.md with the requested behavior.\n2. Inspect test/other/thing.exs.\n3. Add Jason dependency to mix.exs."
        ),
        edit_call("fixture", "implemented"),
        message("Done."),
        message(~s({"verdict":"accept","findings":[]}))
      ])

    opts = options(tmp_dir, provider)
    assert {:ok, pack} = Harness.context_pack(opts, @intent)
    assert pack.files == ["README.md"]
    assert "Kogen.Harness.run/4" in pack.refs
    assert {:ok, %Plan{text: plan_text}} = Harness.plan(opts, pack, @intent)
    assert plan_text =~ "README.md"
    refute plan_text =~ "test/other/thing.exs"
    refute plan_text =~ "Jason dependency"
    refute plan_text =~ "Update mix.exs"
    assert {:ok, result} = Harness.develop(opts, @intent, %Plan{text: plan_text, usage: %{}}, nil)
    assert result.outcome == :done

    assert {:ok, %Review{verdict: :accept, findings: []}} =
             Harness.review(opts, @intent, "diff", %{status: :pass})

    [context_request, summary_request, plan_request, build_request, done_request, review_request] =
      ScriptedProvider.requests(provider)

    assert context_request.model == "gpt-6-luna"
    assert context_request.effort == "low"
    assert Enum.map(context_request.tools, & &1["name"]) == ["read", "search"]
    assert summary_request.model == "gpt-6-luna"
    assert plan_request.model == "gpt-6.1-sol"
    assert plan_request.effort == "high"
    assert plan_request.tools == []
    assert build_request.tools != []
    assert done_request.model == "gpt-6-luna"
    assert review_request.model == "gpt-6.1-sol"
    assert review_request.tools == []
  end

  test "review revise continues one repair pass and then accepts", %{tmp_dir: tmp_dir} do
    provider =
      ScriptedProvider.start([
        edit_call("fixture", "draft"),
        message("Done."),
        message(~s({"verdict":"revise","findings":["A1 does not match the requested value."]})),
        tool_call("edit", edit_args("README.md", "draft", "final"), "repair-edit"),
        message("Repaired and done."),
        message(~s({"verdict":"accept","findings":[]}))
      ])

    opts = options(tmp_dir, provider)
    assert {:ok, initial} = Harness.develop(opts, @intent, nil, nil)
    assert initial.outcome == :done
    assert {:ok, review} = Harness.review(opts, @intent, "diff", %{status: :pass})
    assert review.verdict == :revise
    assert review.findings == ["A1 does not match the requested value."]

    repair_opts = %{opts | repairs_left: 1}
    resume = %{previous_items: initial.items, failure_text: Enum.join(review.findings, "\n")}
    assert {:ok, repaired} = Harness.develop(repair_opts, @intent, nil, resume)
    assert repaired.outcome == :done
    assert {:ok, final_review} = Harness.review(opts, @intent, "repaired diff", %{status: :pass})
    assert final_review.verdict == :accept
    assert File.read!(Path.join(opts.workdir, "README.md")) == "final\n"
    assert length(ScriptedProvider.requests(provider)) == 6
  end

  test "review marks the remainder of diffs beyond its character limit", %{tmp_dir: tmp_dir} do
    provider = ScriptedProvider.start([message(~s({"verdict":"accept","findings":[]}))])
    opts = options(tmp_dir, provider)
    large_diff = "HEAD_OF_DIFF\n" <> String.duplicate("padding\n", 25_000) <> "TAIL_OF_DIFF"

    assert {:ok, %Review{verdict: :accept}} = Harness.review(opts, @intent, large_diff, %{})

    [request] = ScriptedProvider.requests(provider)

    review_input =
      request.input
      |> hd()
      |> Map.fetch!("content")
      |> hd()
      |> Map.fetch!("text")

    assert review_input =~ "HEAD_OF_DIFF"

    assert review_input =~
             "[TRUNCATED: Candidate diff continues beyond the 200,000-character review limit.]"

    refute review_input =~ "TAIL_OF_DIFF"
  end

  defp options(tmp_dir, provider, checks \\ []) do
    workdir = Kogen.Testkit.Git.create!(Path.join(tmp_dir, "candidate"))
    run_dir = Path.join(tmp_dir, "run")

    project = %Project{
      root: workdir,
      name: "fixture",
      checks: checks,
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{"harness" => ["README.md", "lib/kogen/harness", "test/harness"]}
    }

    %Opts{
      workdir: workdir,
      run_dir: run_dir,
      project: project,
      provider_mod: ScriptedProvider,
      provider_config: provider,
      proc_mod: Kogen.Proc,
      changed?: fn -> {:ok, true} end,
      env: %{},
      models: %{builder: {"gpt-6-luna", "low"}, strong: {"gpt-6.1-sol", "high"}},
      limits: %{max_turns: 12, wall_ms: 60_000},
      repairs_left: 2
    }
  end

  defp edit_call(old_text, new_text),
    do: tool_call("edit", edit_args("README.md", old_text, new_text), "edit-#{new_text}")

  defp edit_args(path, old_text, new_text),
    do: %{"path" => path, "old_text" => old_text, "new_text" => new_text}

  defp read_call(path), do: tool_call("read", %{"path" => path}, "read-#{path}")

  defp tool_call(name, arguments, call_id) do
    item = %{
      "type" => "function_call",
      "call_id" => call_id,
      "name" => name,
      "arguments" => arguments
    }

    %ModelResponse{
      id: "response-#{call_id}",
      text: "",
      tool_calls: [%ToolCall{id: call_id, name: name, arguments: arguments}],
      usage: usage(),
      raw_items: [item]
    }
  end

  defp message(text) do
    item = %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }

    %ModelResponse{
      id: "response-text",
      text: text,
      tool_calls: [],
      usage: usage(),
      raw_items: [item]
    }
  end

  defp usage, do: %{input: 10, cached_input: 0, cache_write: 0, output: 5, reasoning: 1}
end
