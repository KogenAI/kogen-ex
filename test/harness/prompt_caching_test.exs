defmodule Kogen.Harness.PromptCachingTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Plan
  alias Kogen.Provider.ChatGPT.Codec
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.HarnessScriptedProvider, as: ScriptedProvider

  @intent "Approved Intent: change README, preserve the public interface."

  test "scripted Build stages preserve every prior prompt byte, including reasoning", %{
    tmp_dir: root
  } do
    opts = options(root)

    keys =
      for stage <- [:develop, :plan, :context, :shape] do
        responses =
          if stage == :develop do
            [read_response(1), read_response(2), finish_response()]
          else
            [read_response(1), read_response(2), message(), message()]
          end

        provider = ScriptedProvider.start(responses)

        opts = %{opts | provider_config: provider}
        assert {:ok, result} = run(stage, opts)
        requests = ScriptedProvider.requests(provider)
        assert length(requests) == 3
        assert_prefixes(requests)

        assert Enum.at(requests, 1).input |> Enum.drop(1) |> hd() |> Access.get("type") ==
                 "reasoning"

        # Both backends carry the same stable affinity key.
        for request <- requests, mode <- [:codex, :siwc] do
          assert {:ok, encoded} = Codec.encode_request(request, mode)
          body = :json.decode(encoded)
          assert body["prompt_cache_key"] == hd(requests).prompt_cache_key
          assert body["store"] == false
          refute Map.has_key?(body, "previous_response_id")
        end

        if stage == :shape do
          assert {:ok, _repair} =
                   Harness.shape(
                     opts,
                     "cache-fixture",
                     @intent,
                     result.items,
                     "Repair validation",
                     3
                   )

          repaired = ScriptedProvider.requests(provider)
          assert length(repaired) == 4
          assert_prefixes(repaired)
        end

        hd(requests).prompt_cache_key
      end

    assert length(Enum.uniq(keys)) == 4
  end

  test "parallel rungs have distinct keys and repairs retain the original conversation", %{
    tmp_dir: root
  } do
    opts = options(root)

    keys =
      for {attempt, rung} <- [
            {:builder, "builder"},
            {:builder, "fresh-1"},
            {:builder, "fresh-2"},
            {:escalation, "builder"}
          ] do
        provider =
          ScriptedProvider.start([
            read_response(1),
            read_response(2),
            finish_response(),
            finish_response()
          ])

        opts = %{
          opts
          | provider_config: provider,
            request_tags: %{attempt: attempt, rung: rung}
        }

        assert {:ok, first} = Harness.develop(opts, @intent, nil, nil)

        resume = %{previous_items: first.items, failure_text: "A1: deterministic gate failed"}
        assert {:ok, _repair} = Harness.develop(%{opts | repairs_left: 1}, @intent, nil, resume)
        requests = ScriptedProvider.requests(provider)
        assert length(requests) == 4
        assert_prefixes(requests)
        assert inspect(List.last(requests).input) =~ "A1: deterministic gate failed"
        hd(requests).prompt_cache_key
      end

    assert Enum.all?(keys, &(is_binary(&1) and byte_size(&1) == 64))
    assert length(Enum.uniq(keys)) == 4
  end

  test "late budget reminder appends to the prompt and survives subsequent turns", %{
    tmp_dir: root
  } do
    provider = ScriptedProvider.start(for turn <- 1..10, do: read_response(turn))
    opts = %{options(root) | provider_config: provider, limits: %{max_turns: 10, wall_ms: 60_000}}
    assert {:ok, %{outcome: :turn_cap}} = Harness.develop(opts, @intent, nil, nil)
    requests = ScriptedProvider.requests(provider)
    assert_prefixes(requests)
    assert inspect(Enum.at(requests, 8).input) =~ "System note: 2 turns remain."
    assert inspect(Enum.at(requests, 9).input) =~ "System note: 2 turns remain."
  end

  defp assert_prefixes(requests) do
    for {earlier, later} <- Enum.zip(requests, tl(requests)), mode <- [:codex, :siwc] do
      assert earlier.prompt_cache_key == later.prompt_cache_key
      assert {:ok, before_bytes} = Codec.encode_request(earlier, mode)
      assert {:ok, after_bytes} = Codec.encode_request(later, mode)

      # A closed JSON document cannot be a prefix of a larger valid document.
      # Remove only the input array/object closers, retaining every prompt byte
      # and every static field of the actual wire encoding.
      assert String.ends_with?(before_bytes, "]}")
      prefix = binary_part(before_bytes, 0, byte_size(before_bytes) - 2)
      assert String.starts_with?(after_bytes, prefix)
      assert binary_part(before_bytes, byte_size(prefix), 1) == "]"
      assert binary_part(after_bytes, byte_size(prefix), 1) == ","
      assert Enum.take(later.input, length(earlier.input)) == earlier.input
    end
  end

  defp run(:develop, opts),
    do:
      Harness.develop(
        opts,
        @intent,
        %Plan{text: "Stable implementation plan advice.", usage: %{}},
        nil
      )

  defp run(:plan, opts), do: Harness.plan(opts, nil, @intent)
  defp run(:context, opts), do: Harness.context_pack(opts, @intent)
  defp run(:shape, opts), do: Harness.shape(opts, "cache-fixture", @intent, [], nil, 0)

  defp options(root) do
    workdir = Git.create!(Path.join(root, "candidate"))

    %Opts{
      workdir: workdir,
      run_dir: Path.join(root, "run"),
      project: %Project{
        root: workdir,
        name: "fixture",
        checks: [],
        setup: [],
        fix: [],
        diagnose: [],
        protected_paths: [],
        domains: %{"harness" => ["README.md"]}
      },
      provider_mod: ScriptedProvider,
      provider_config: nil,
      proc_mod: Kogen.Proc,
      changed?: fn -> {:ok, true} end,
      limits: %{max_turns: 12, wall_ms: 60_000}
    }
  end

  defp read_response(turn) do
    id = "read-#{turn}"
    arguments = %{"path" => "README.md"}

    %ModelResponse{
      id: "response-#{turn}",
      text: "",
      tool_calls: [%ToolCall{id: id, name: "read", arguments: arguments}],
      usage: %{input: 20, cached_input: 980, output: 10, reasoning: 5},
      raw_items: [
        %{
          "type" => "reasoning",
          "id" => "reason-#{turn}",
          "encrypted_content" => "opaque-#{turn}",
          "summary" => []
        },
        %{
          "type" => "function_call",
          "call_id" => id,
          "name" => "read",
          "arguments" => ~s({"path":"README.md"})
        }
      ]
    }
  end

  defp message do
    %ModelResponse{
      id: "response-done",
      text: "Done.",
      tool_calls: [],
      usage: %{input: 20, cached_input: 980, output: 10, reasoning: 5},
      raw_items: [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Done."}]
        }
      ]
    }
  end

  defp finish_response do
    %ModelResponse{
      id: "response-finish",
      text: "",
      tool_calls: [%ToolCall{id: "finish", name: "finish", arguments: %{}}],
      usage: %{},
      raw_items: [
        %{
          "type" => "function_call",
          "call_id" => "finish",
          "name" => "finish",
          "arguments" => "{}"
        }
      ]
    }
  end
end
