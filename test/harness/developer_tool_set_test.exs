defmodule Kogen.Harness.DeveloperToolSetTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.HarnessScriptedProvider, as: ScriptedProvider

  @intent """
  ---
  title: Shell-only Harness fixture
  size: small
  domains: [harness]
  ---
  Change the fixture README.

  ## Acceptance
  - A1: README contains the requested value.

  ## Verify
  - A1: test
  """

  test "shell builder exposes only shell and receives concise shell workflow guidance", %{
    tmp_dir: tmp_dir
  } do
    provider =
      ScriptedProvider.start([
        tool_call("shell", %{"cmd" => "printf 'shell-built\\n' > README.md"}, "shell-edit"),
        message("Done.")
      ])

    opts = options(tmp_dir, provider, :shell)

    assert {:ok, result} = Harness.develop(opts, @intent, nil, nil)
    assert result.outcome == :done
    assert File.read!(Path.join(opts.workdir, "README.md")) == "shell-built\n"

    [request, _done_request] = ScriptedProvider.requests(provider)
    assert Enum.map(request.tools, & &1["name"]) == ["shell"]
    assert request.instructions =~ "sed -n"
    assert request.instructions =~ "python3"
  end

  test "turn cap adds one system note at 80 percent and reports turn_cap", %{
    tmp_dir: tmp_dir
  } do
    provider =
      ScriptedProvider.start(
        for turn <- 1..10 do
          tool_call("read", %{"path" => "README.md"}, "read-#{turn}")
        end
      )

    opts = options(tmp_dir, provider)
    opts = %{opts | limits: %{max_turns: 10, wall_ms: 60_000}}

    assert {:ok, result} = Harness.develop(opts, @intent, nil, nil)
    assert result.outcome == :turn_cap
    assert result.turns == 10

    requests = ScriptedProvider.requests(provider)
    assert length(requests) == 10

    noted_requests =
      requests
      |> Enum.with_index(1)
      |> Enum.filter(fn {request, _turn} ->
        String.contains?(request.instructions, "System note:")
      end)

    assert [{note_request, 9}] = noted_requests
    assert note_request.instructions =~ "System note: 2 turns remain."

    assert note_request.instructions =~
             "Run the targeted tests now and finish the smallest complete change."
  end

  defp options(tmp_dir, provider, builder_tools \\ :full) do
    workdir = Git.create!(Path.join(tmp_dir, "candidate"))

    project = %Project{
      root: workdir,
      name: "fixture",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{"harness" => ["README.md"]}
    }

    %Opts{
      workdir: workdir,
      run_dir: Path.join(tmp_dir, "run"),
      project: project,
      provider_mod: ScriptedProvider,
      provider_config: provider,
      proc_mod: Kogen.Proc,
      env: %{},
      changed?: fn -> {:ok, true} end,
      builder_tools: builder_tools,
      limits: %{max_turns: 12, wall_ms: 60_000},
      repairs_left: 2
    }
  end

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
      id: "response-done",
      text: text,
      tool_calls: [],
      usage: usage(),
      raw_items: [item]
    }
  end

  defp usage, do: %{input: 10, cached_input: 0, cache_write: 0, output: 5, reasoning: 1}
end
