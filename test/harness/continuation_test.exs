defmodule Kogen.Harness.ContinuationTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Testkit.Git

  # Six real tool histories need more than the default timeout on a loaded machine.
  @tag timeout: 180_000
  test "long investigations continue with obligations and disproven approaches, with measured receipts",
       %{tmp_dir: tmp_dir} do
    for_result =
      for scenario <- ["return shape cascade", "protocol dispatch investigation"] do
        for {limit, cap} <- [{nil, 32_000}, {nil, :infinity}, {16_000, 32_000}] do
          root = Path.join(tmp_dir, "#{scenario}-#{limit || 0}-#{cap}")
          File.mkdir_p!(root)
          opts = options(root, limit)
          Agent.update(opts.provider_config, &Map.put(&1, :cap, cap))

          result =
            Harness.develop(
              opts,
              "Preserve public API. Acceptance: write fixed to result.txt.",
              nil,
              nil
            )

          if limit do
            rows =
              opts.run_dir
              |> Path.join("requests.jsonl")
              |> File.read!()
              |> String.split("\n", trim: true)
              |> Enum.map(&Jason.decode!/1)

            keys =
              rows
              |> Enum.filter(&(&1["record_kind"] == "model_request"))
              |> Enum.map(& &1["conversation_id"])

            # Original conversation, checkpoint request, and compacted continuation.
            assert length(Enum.uniq(keys)) >= 3
            assert hd(keys) == Enum.at(keys, 1)
          end

          stats = Agent.get(opts.provider_config, & &1)
          success = File.exists?(Path.join(opts.workdir, "result.txt"))

          if limit || cap == :infinity,
            do: assert(match?({:ok, %{outcome: :done}}, result)),
            else: assert(match?({:error, _}, result))

          assert stats.investigations == if(limit || cap == :infinity, do: 12, else: 8)
          assert success == (limit != nil || cap == :infinity)
          if success, do: assert(File.read!(Path.join(opts.workdir, "result.txt")) == "fixed")

          %{
            task: scenario,
            policy: if(limit, do: "checkpoint", else: "current-#{cap}"),
            delivered: success,
            input_tokens: stats.tokens,
            repeated_work: length(stats.steps) - length(Enum.uniq(stats.steps))
          }
        end
      end

    measurements = List.flatten(for_result)

    report = Path.join(tmp_dir, "comparison.json")
    File.write!(report, Jason.encode!(measurements))
    decoded = Jason.decode!(File.read!(report))
    assert Enum.count(decoded, & &1["delivered"]) == 4
    IO.puts("Continuation comparison: " <> File.read!(report))
  end

  test "malformed checkpoint fails visibly without dropping history", %{tmp_dir: tmp_dir} do
    opts = options(tmp_dir, 16_000)
    Agent.update(opts.provider_config, &Map.put(&1, :malformed, true))

    assert {:error, %{reason: :continuation_failed}} =
             Harness.develop(opts, "Acceptance: fixed", nil, nil)

    transcript = File.read!(Path.join(opts.run_dir, "transcript.jsonl"))
    assert transcript =~ "read investigation"
    refute transcript =~ "context_continued"
  end

  @tag :checkpoint_receipts
  test "separate Developer passes retain distinct checkpoint receipt files", %{tmp_dir: root} do
    opts = options(root, 16_000)

    files =
      Enum.reduce(1..2, [], fn _pass, existing ->
        Agent.update(opts.provider_config, &%{&1 | investigations: 8, checkpoints: 0, steps: []})

        assert {:ok, %{outcome: :done}} =
                 Harness.develop(
                   opts,
                   "Preserve public API. Acceptance: write fixed to result.txt.",
                   nil,
                   nil
                 )

        current = Path.wildcard(Path.join(opts.run_dir, "continuation-*.md"))
        assert length(current) == length(existing) + 1
        Enum.each(existing, fn path -> assert File.read!(path) =~ "ruled_out" end)
        current
      end)

    assert length(files) == 2
  end

  defp options(root, limit) do
    workdir = Git.create!(Path.join(root, "candidate"))

    {:ok, provider} =
      Agent.start_link(fn ->
        %{investigations: 0, tokens: 0, malformed: false, checkpoints: 0, cap: 32_000, steps: []}
      end)

    project = %Project{
      root: workdir,
      name: "fixture",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{},
      build: %{context_bytes: limit}
    }

    %Opts{
      workdir: workdir,
      run_dir: Path.join(root, "run"),
      project: project,
      provider_mod: __MODULE__.Provider,
      provider_config: provider,
      proc_mod: Kogen.Proc,
      changed?: fn -> {:ok, File.exists?(Path.join(workdir, "result.txt"))} end,
      limits: %{max_turns: 30, wall_ms: 60_000}
    }
  end

  defmodule Provider do
    @moduledoc false
    @behaviour Kogen.Contracts.ProviderPort

    def respond(pid, request) do
      Agent.get_and_update(pid, fn state ->
        bytes = :erlang.iolist_size(:json.encode(request.input))
        next = %{state | tokens: state.tokens + div(bytes + 3, 4)}
        {response, next} = reply(request, next, bytes)
        {response, next}
      end)
    end

    defp reply(request, state, bytes) do
      cond do
        is_integer(state.cap) and bytes > state.cap ->
          {{:error,
            %Kogen.Contracts.ProviderError{
              class: :malformed,
              message: "fixture usable context exceeded"
            }}, state}

        request.tools == [] ->
          checkpoint_reply(state)

        state.investigations < 12 ->
          verify_checkpoint(request, state)

          call =
            tool(
              "printf 'read investigation #{state.investigations}: disproven API replacement\\n'; printf '%04000d\\n' 0",
              "investigation-#{state.investigations}"
            )

          {{:ok, call},
           %{
             state
             | investigations: state.investigations + 1,
               steps: [state.investigations | state.steps]
           }}

        state.investigations == 12 ->
          {{:ok, tool("printf fixed > result.txt", "edit")}, %{state | investigations: 13}}

        true ->
          {{:ok, finish()}, %{state | investigations: 12}}
      end
    end

    defp finish do
      %ModelResponse{
        id: "finish",
        text: "",
        tool_calls: [%ToolCall{id: "finish", name: "finish", arguments: %{}}],
        usage: %{},
        raw_items: []
      }
    end

    defp checkpoint_reply(state) do
      checkpoint = %{
        obligations: "Preserve public API; result.txt must contain fixed",
        findings: "Wrong tuple shape originates in decoder",
        investigation: "read investigation found callers expect {:ok, value}",
        ruled_out: "Do not change downstream callers: replacing API was disproven",
        next_steps: "Complete remaining investigations then write fixed to result.txt"
      }

      text = if state.malformed, do: "missing obligations", else: Jason.encode!(checkpoint)
      {{:ok, message(text)}, %{state | checkpoints: state.checkpoints + 1}}
    end

    defp verify_checkpoint(request, state) do
      if state.checkpoints > 0 do
        input = Jason.encode!(request.input)
        true = String.contains?(input, "Preserve public API")
        true = String.contains?(input, "disproven")
      end
    end

    defp tool(cmd, id) do
      arguments = %{"cmd" => cmd}

      %ModelResponse{
        id: id,
        text: "",
        tool_calls: [%ToolCall{id: id, name: "shell", arguments: arguments}],
        usage: %{},
        raw_items: [
          %{
            "type" => "function_call",
            "name" => "shell",
            "arguments" => arguments,
            "call_id" => id
          }
        ]
      }
    end

    defp message(text),
      do: %ModelResponse{
        id: "summary",
        text: text,
        tool_calls: [],
        usage: %{},
        raw_items: [
          %{
            "role" => "assistant",
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => text}]
          }
        ]
      }
  end
end
