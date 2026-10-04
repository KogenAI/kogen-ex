defmodule Kogen.Harness.ReadSearchSandboxTests do
  @moduledoc false
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Proc.Sandbox
  alias Kogen.Testkit.HarnessScriptedProvider, as: ScriptedProvider

  test "shaper search falls back to grep when sandboxed rg is unavailable", %{
    tmp_dir: tmp_dir
  } do
    provider =
      ScriptedProvider.start([
        tool_call(
          "search",
          %{"pattern" => "KOGEN_TEXT_THAT_CANNOT_EXIST_93761", "path" => "."},
          "search-no-match"
        ),
        message("No matching context was found.")
      ])

    opts = options(tmp_dir, provider)

    sandbox = %Sandbox{
      enabled: true,
      home: tmp_dir,
      project_root: opts.workdir,
      origin: opts.workdir,
      workspace: opts.workdir,
      run_dir: opts.run_dir,
      tmp_dir: tmp_dir,
      workspace_is_project: true
    }

    opts = %{opts | env: %{"PATH" => "/usr/bin:/bin"}, sandbox: sandbox}

    assert {:ok, result} = Harness.shape(opts, "fixture", "Describe this project.", [], nil, 0)
    assert result.text == "No matching context was found."

    request_inputs = provider |> ScriptedProvider.requests() |> Enum.map(&inspect(&1.input))
    assert Enum.any?(request_inputs, &String.contains?(&1, "No matches."))
  end

  defp options(tmp_dir, provider) do
    workdir = Kogen.Testkit.Git.create!(Path.join(tmp_dir, "candidate"))
    run_dir = Path.join(tmp_dir, "run")

    project = %Project{
      root: workdir,
      name: "fixture",
      checks: [],
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
      models: %{builder: {"gpt-6-luna", "low"}, strong: {"gpt-6-luna", "high"}},
      limits: %{max_turns: 12, wall_ms: 60_000}
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
      id: "response-text",
      text: text,
      tool_calls: [],
      usage: usage(),
      raw_items: [item]
    }
  end

  defp usage, do: %{input: 10, cached_input: 0, cache_write: 0, output: 5, reasoning: 1}
end
