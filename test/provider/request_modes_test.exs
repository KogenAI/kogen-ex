defmodule Kogen.Provider.RequestModesTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT.Codec

  test "conventional and Lite requests match the pinned golden wire shapes" do
    for adapter <- [:responses, :lite] do
      request = request(adapter)
      assert {:ok, encoded} = Codec.encode_request(request)
      golden = File.read!(Path.join(__DIR__, "fixtures/#{adapter}-request.json"))
      assert :json.decode(encoded) == :json.decode(golden)
      assert {:ok, ^encoded} = Codec.encode_request(request)
    end
  end

  test "Lite identities change only when their payload or session changes" do
    first = body(request(:lite))["input"]
    [tools, instructions | _history] = first
    changed = body(%{request(:lite) | instructions: "Different instructions"})["input"]
    assert hd(changed) == tools
    refute Enum.at(changed, 1)["id"] == instructions["id"]

    refute hd(body(%{request(:lite) | session_id: "another-session"})["input"])["id"] ==
             tools["id"]

    assert Enum.drop(first, 2) == request(:lite).input
  end

  test "unsupported backend and invalid Lite controls cannot silently fall back" do
    assert {:error, %ProviderError{class: :unsupported}} =
             Codec.encode_request(request(:lite), :siwc)

    for overrides <- [
          %{model: "gpt-6.1-sol"},
          %{parallel_tool_calls: true},
          %{reasoning_context: nil},
          %{session_id: nil}
        ] do
      assert {:error, %ProviderError{}} =
               Codec.encode_request(Map.merge(request(:lite), overrides))
    end
  end

  test "summary none is omitted and effort is preserved in both modes" do
    for adapter <- [:responses, :lite] do
      assert body(request(adapter))["reasoning"]["effort"] == "max"
      refute Map.has_key?(body(request(adapter))["reasoning"], "summary")

      assert body(%{request(adapter) | reasoning_summary: :auto})["reasoning"]["summary"] ==
               "auto"
    end
  end

  test "generation caps serialize independently on public shapes and fail explicitly for Lite" do
    request = %{request(:responses) | model_generation_tokens: 12_000}

    for mode <- [:codex, :siwc] do
      assert {:ok, encoded} = Codec.encode_request(request, mode)
      body = :json.decode(encoded)
      assert body["max_output_tokens"] == 12_000
      assert body["reasoning"]["effort"] == "max"
      refute Map.has_key?(body, "tool_result_tokens")
    end

    assert {:error, %ProviderError{class: :unsupported}} =
             Codec.encode_request(%{request(:lite) | model_generation_tokens: 12_000})
  end

  test "an unsupported endpoint rejects a generation cap before credential access", %{
    tmp_dir: tmp
  } do
    config = %Kogen.Provider.ChatGPT.Config{
      endpoint: "https://chatgpt.com/backend-api/codex/responses",
      timeout_ms: 30_000,
      credential_path: Path.join(tmp, "missing-test-credential")
    }

    assert {:error, %ProviderError{class: :unsupported}} =
             Kogen.Provider.ChatGPT.respond(config, %{
               request(:responses)
               | model_generation_tokens: 12_000
             })
  end

  defp body(request) do
    {:ok, encoded} = Codec.encode_request(request)
    :json.decode(encoded)
  end

  defp request(adapter) do
    %ModelRequest{
      model: "gpt-6-luna",
      effort: "max",
      instructions: "Build it.",
      input: [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Fix it."}]}],
      tools: [%{"type" => "function", "name" => "shell", "parameters" => %{"type" => "object"}}],
      previous_response_id: nil,
      session_id: "test-session",
      adapter: adapter,
      reasoning_summary: :none,
      reasoning_context: if(adapter == :lite, do: :all_turns),
      text_verbosity: :low
    }
  end
end
