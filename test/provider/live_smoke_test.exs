defmodule Kogen.Provider.ChatGPT.LiveSmokeTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT
  alias Kogen.Testkit.BenchmarkAuth

  @tag :live
  test "gpt-6-luna and gpt-6.1-sol answer tiny live requests" do
    if live_selected?() do
      run_smoke()
    else
      IO.puts("Live provider smoke is opt-in; run mix test --only live to execute it.")
      assert true
    end
  end

  defp run_smoke do
    case BenchmarkAuth.config() do
      {:ok, config} ->
        Enum.each(["gpt-6-luna", "gpt-6.1-sol"], fn model ->
          assert {:ok, response} = ChatGPT.respond(config, request(model))
          assert is_binary(response.text) and response.text != ""
        end)

      {:error, :benchmark_auth_unavailable} ->
        IO.puts("Live provider smoke skipped: set KOGEN_AUTH_PATH in the benchmark/CI job.")
        assert true

      {:error, %ProviderError{class: :login}} ->
        IO.puts("Live provider smoke skipped: benchmark credentials are unavailable or expired.")
        assert true
    end
  end

  defp live_selected? do
    ExUnit.configuration()
    |> Keyword.get(:include, [])
    |> Enum.any?(&(&1 == :live or match?({:live, _value}, &1)))
  end

  defp request(model) do
    %ModelRequest{
      model: model,
      effort: "low",
      instructions: "Reply with the single word ok.",
      input: [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "ok"}]}],
      tools: [],
      previous_response_id: nil
    }
  end
end
