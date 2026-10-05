defmodule Kogen.Harness.ExchangeResilienceTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ProviderError
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request
  alias Kogen.Harness.Opts
  alias Kogen.Provider.ChatGPT
  alias Kogen.Resilience.Policy
  alias Kogen.Testkit.FakeResponsesServer

  @fast %Policy{backoff_base_ms: 10, backoff_max_ms: 20}
  @overloaded {:status, 503, ~s({"error":{"message":"overloaded"}})}

  describe "per-request caps" do
    test "a slow first byte is aborted at the first-byte cap and retried", %{tmp_dir: tmp_dir} do
      {url, server} = FakeResponsesServer.start([:hang, {:ok, "recovered"}])

      opts = opts(tmp_dir, url, %{first_byte_timeout_ms: 150, timeout_ms: 30_000}, @fast)
      started = System.monotonic_time(:millisecond)

      assert {:ok, %{text: "recovered"}} = Exchange.respond(opts, request())
      assert System.monotonic_time(:millisecond) - started < 5_000
      assert_receive {:fake_request, 1, _body, _at}
      assert_receive {:fake_request, 2, _body, _at}
      assert_receive {:recorded, %{event: :provider_retry, reason: :timeout, attempt: 1}}
      FakeResponsesServer.stop(server)
    end

    test "a stream that keeps trickling is cut off by the total cap and retried", %{
      tmp_dir: tmp_dir
    } do
      {url, server} = FakeResponsesServer.start([:trickle, {:ok, "recovered"}])

      config = %{first_byte_timeout_ms: 5_000, timeout_ms: 5_000, total_timeout_ms: 400}
      opts = opts(tmp_dir, url, config, @fast)

      assert {:ok, %{text: "recovered"}} = Exchange.respond(opts, request())
      assert_receive {:fake_request, 1, _body, first_at}
      assert_receive {:fake_request, 2, _body, second_at}
      assert second_at - first_at >= 400
      assert_receive {:recorded, %{event: :provider_retry, reason: :timeout}}
      FakeResponsesServer.stop(server)
    end

    test "the exchange enforces its own per-attempt cap on any provider", %{tmp_dir: tmp_dir} do
      {url, server} = FakeResponsesServer.start([:hang, {:ok, "recovered"}])
      policy = %{@fast | request_cap_ms: 200}
      opts = opts(tmp_dir, url, %{first_byte_timeout_ms: 30_000, timeout_ms: 30_000}, policy)

      assert {:ok, %{text: "recovered"}} = Exchange.respond(opts, request())
      assert_receive {:recorded, %{event: :provider_retry, reason: :timeout}}
      FakeResponsesServer.stop(server)
    end
  end

  describe "stream idle timeout" do
    test "a stream that goes silent after its first byte is aborted at the idle timeout and retried",
         %{tmp_dir: tmp_dir} do
      {url, server} = FakeResponsesServer.start([:stall, {:ok, "recovered"}])
      opts = opts(tmp_dir, url, %{timeout_ms: 30_000}, %{@fast | stream_idle_ms: 300})

      assert {:ok, %{text: "recovered"}} = Exchange.respond(opts, request())
      assert_receive {:fake_request, 1, _body, first_at}
      assert_receive {:fake_request, 2, _body, second_at}
      assert second_at - first_at >= 300 and second_at - first_at < 5_000
      assert_receive {:recorded, %{event: :provider_retry, reason: :stall, attempt: 1}}
      FakeResponsesServer.stop(server)
    end

    test "keepalive comments do not keep a silent stream alive", %{tmp_dir: tmp_dir} do
      {url, server} = FakeResponsesServer.start([:keepalive_stall, {:ok, "recovered"}])
      opts = opts(tmp_dir, url, %{timeout_ms: 30_000}, %{@fast | stream_idle_ms: 300})

      assert {:ok, %{text: "recovered"}} = Exchange.respond(opts, request())
      assert_receive {:recorded, %{event: :provider_retry, reason: :stall}}
      FakeResponsesServer.stop(server)
    end

    test "a slow but steadily streaming response is not cut", %{tmp_dir: tmp_dir} do
      {url, server} = FakeResponsesServer.start([{:steady, "slow", 8, 100}, {:ok, "retried"}])
      opts = opts(tmp_dir, url, %{timeout_ms: 30_000}, %{@fast | stream_idle_ms: 300})
      started = System.monotonic_time(:millisecond)

      assert {:ok, %{text: "slow"}} = Exchange.respond(opts, request())
      assert System.monotonic_time(:millisecond) - started >= 800
      refute_received {:fake_request, 2, _body, _at}
      refute_received {:recorded, %{event: :provider_retry}}
      FakeResponsesServer.stop(server)
    end

    test "stalls are retried past max_attempts while the wall budget lasts", %{tmp_dir: tmp_dir} do
      script = List.duplicate(:stall, 5) ++ [{:ok, "persisted"}]
      {url, server} = FakeResponsesServer.start(script)
      opts = opts(tmp_dir, url, %{timeout_ms: 30_000}, %{@fast | stream_idle_ms: 100})

      assert {:ok, %{text: "persisted"}} = Exchange.respond(opts, request())
      assert_receive {:fake_request, 6, _body, _at}
      FakeResponsesServer.stop(server)
    end

    test "without a wall budget stalls stop at max_attempts", %{tmp_dir: tmp_dir} do
      {url, server} = FakeResponsesServer.start([:stall, :stall, {:ok, "too late"}])
      policy = %{@fast | stream_idle_ms: 100, max_attempts: 2}
      opts = opts(tmp_dir, url, %{timeout_ms: 30_000}, policy)

      assert {:error, %ProviderError{class: :stall}} =
               Exchange.respond(opts, %{request() | remaining_ms: :infinity})

      refute_receive {:fake_request, 3, _body, _at}, 200
      FakeResponsesServer.stop(server)
    end
  end

  describe "retried classes" do
    for {name, behaviour, reason} <- [
          {"timeout", :hang, :timeout},
          {"transport", :close, :transport},
          {"overload", @overloaded, :overload},
          {"malformed", {:status, 400, "bad request"}, :malformed}
        ] do
      test "#{name} errors are retried until the request succeeds", %{tmp_dir: tmp_dir} do
        {url, server} = FakeResponsesServer.start([unquote(Macro.escape(behaviour)), {:ok, "ok"}])
        opts = opts(tmp_dir, url, %{first_byte_timeout_ms: 150}, @fast)

        assert {:ok, %{text: "ok"}} = Exchange.respond(opts, request())
        assert_receive {:fake_request, 2, _body, _at}
        expected = unquote(reason)
        assert_receive {:recorded, %{event: :provider_retry, reason: ^expected, delay_ms: delay}}
        assert delay >= 5 and delay <= 10
        FakeResponsesServer.stop(server)
      end
    end

    test "attempts stop at four and the last error is returned", %{tmp_dir: tmp_dir} do
      {url, server} = FakeResponsesServer.start([{:status, 400, "bad request"}])
      opts = opts(tmp_dir, url, %{}, @fast)

      assert {:error, %ProviderError{class: :malformed}} = Exchange.respond(opts, request())
      for index <- 1..4, do: assert_receive({:fake_request, ^index, _body, _at})
      refute_receive {:fake_request, 5, _body, _at}, 200
      FakeResponsesServer.stop(server)
    end

    test "backoff grows exponentially with jitter up to its ceiling" do
      policy = %Policy{backoff_base_ms: 2_000, backoff_max_ms: 60_000}

      for {failed, ceiling} <- [{1, 2_000}, {2, 4_000}, {3, 8_000}, {10, 60_000}],
          _sample <- 1..20 do
        delay = Policy.backoff_ms(policy, failed)
        assert delay >= div(ceiling, 2) and delay <= ceiling
      end
    end

    test "no retry is attempted once the wall budget cannot cover the backoff", %{
      tmp_dir: tmp_dir
    } do
      {url, server} = FakeResponsesServer.start([@overloaded, {:ok, "late"}])
      policy = %Policy{backoff_base_ms: 5_000, backoff_max_ms: 5_000, fallbacks: %{}}
      opts = opts(tmp_dir, url, %{}, policy)

      assert {:error, %ProviderError{class: :overload}} =
               Exchange.respond(opts, %{request() | remaining_ms: 2_000})

      assert_receive {:fake_request, 1, _body, _at}
      refute_receive {:fake_request, 2, _body, _at}, 200
      FakeResponsesServer.stop(server)
    end
  end

  describe "errors that are never retried" do
    for {name, behaviour, class} <- [
          {"usage limit", {:status, 429, ~s({"detail":"usage limit reached"})}, :usage_limit},
          {"login", {:status, 401, ~s({"detail":"login rejected"})}, :login}
        ] do
      test "#{name} errors fail on the first attempt", %{tmp_dir: tmp_dir} do
        {url, server} = FakeResponsesServer.start([unquote(Macro.escape(behaviour)), {:ok, "no"}])
        opts = opts(tmp_dir, url, %{}, @fast)
        expected = unquote(class)

        assert {:error, %ProviderError{class: ^expected}} = Exchange.respond(opts, request())
        assert_receive {:fake_request, 1, _body, _at}
        refute_receive {:fake_request, 2, _body, _at}, 200
        refute_received {:recorded, %{event: :provider_retry}}
        FakeResponsesServer.stop(server)
      end
    end
  end

  describe "model fallback" do
    test "two consecutive overloads move the builder to the next model and record it", %{
      tmp_dir: tmp_dir
    } do
      {url, server} = FakeResponsesServer.start([@overloaded, @overloaded, {:ok, "fallback"}])
      opts = opts(tmp_dir, url, %{}, @fast)
      reasoning = %{"type" => "reasoning", "encrypted_content" => "luna-only"}
      message = %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "hi"}]}

      assert {:ok, %{text: "fallback"}} =
               Exchange.respond(opts, %{request() | items: [message, reasoning]})

      assert_receive {:fake_request, 1, %{"model" => "gpt-6-luna"}, _at}
      assert_receive {:fake_request, 2, %{"model" => "gpt-6-luna"}, _at}
      assert_receive {:fake_request, 3, %{"model" => "gpt-6.1-sol"} = body, _at}
      assert body["reasoning"] == %{"effort" => "medium"}
      assert Enum.map(body["input"], & &1["type"]) == [nil]

      assert_receive {:recorded,
                      %{
                        event: :model_fallback,
                        from: %{model: "gpt-6-luna", effort: "max"},
                        to: %{model: "gpt-6.1-sol", effort: "medium"}
                      }}

      FakeResponsesServer.stop(server)
    end

    test "the planner falls back from Sol high to Sol medium", %{tmp_dir: tmp_dir} do
      {url, server} = FakeResponsesServer.start([@overloaded, @overloaded, {:ok, "plan"}])
      opts = opts(tmp_dir, url, %{}, @fast)

      planner = %{request() | stage: :plan, model: "gpt-6.1-sol", effort: "high"}
      assert {:ok, %{text: "plan"}} = Exchange.respond(opts, planner)

      assert_receive {:fake_request, 3, %{"model" => "gpt-6.1-sol"} = body, _at}
      assert body["reasoning"] == %{"effort" => "medium"}
      assert_receive {:recorded, %{event: :model_fallback, to: %{effort: "medium"}}}
      FakeResponsesServer.stop(server)
    end

    test "a non-overload error between overloads resets the streak", %{tmp_dir: tmp_dir} do
      script = [@overloaded, {:status, 400, "bad"}, @overloaded, {:ok, "same model"}]
      {url, server} = FakeResponsesServer.start(script)
      opts = opts(tmp_dir, url, %{}, @fast)

      assert {:ok, %{text: "same model"}} = Exchange.respond(opts, request())
      assert_receive {:fake_request, 4, %{"model" => "gpt-6-luna"}, _at}
      refute_received {:recorded, %{event: :model_fallback}}
      FakeResponsesServer.stop(server)
    end

    test "fallback lists are configurable per role", %{tmp_dir: tmp_dir} do
      {url, server} = FakeResponsesServer.start([@overloaded, @overloaded, {:ok, "custom"}])
      policy = %{@fast | fallbacks: %{builder: [{"gpt-6-terra", "low"}]}}
      opts = opts(tmp_dir, url, %{}, policy)

      assert {:ok, %{text: "custom"}} = Exchange.respond(opts, request())
      assert_receive {:fake_request, 3, %{"model" => "gpt-6-terra"}, _at}
      FakeResponsesServer.stop(server)
    end
  end

  describe "model fallback disabled" do
    test "repeated overloads retry the same model and never switch", %{tmp_dir: tmp_dir} do
      script = List.duplicate(@overloaded, 6) ++ [{:ok, "same model"}]
      {url, server} = FakeResponsesServer.start(script)
      opts = opts(tmp_dir, url, %{}, %{@fast | model_fallback: false})

      assert {:ok, %{text: "same model"}} = Exchange.respond(opts, request())

      for number <- 1..7 do
        assert_receive {:fake_request, ^number, %{"model" => "gpt-6-luna"}, _at}
      end

      refute_received {:fake_request, 8, _body, _at}
      refute_received {:recorded, %{event: :model_fallback}}
      FakeResponsesServer.stop(server)
    end

    test "overloads are retried until the wall budget ends", %{tmp_dir: tmp_dir} do
      {url, server} = FakeResponsesServer.start(List.duplicate(@overloaded, 40))
      policy = %{@fast | model_fallback: false, max_attempts: 2}
      opts = opts(tmp_dir, url, %{}, policy)

      assert {:error, %ProviderError{class: :timeout}} =
               Exchange.respond(opts, %{request() | remaining_ms: 4_000})

      assert_receive {:fake_request, 3, %{"model" => "gpt-6-luna"}, _at}
      refute_received {:recorded, %{event: :model_fallback}}
      FakeResponsesServer.stop(server)
    end

    test "without a wall budget overloads still stop at max_attempts", %{tmp_dir: tmp_dir} do
      {url, server} = FakeResponsesServer.start(List.duplicate(@overloaded, 4))
      policy = %{@fast | model_fallback: false, max_attempts: 2}
      opts = opts(tmp_dir, url, %{}, policy)

      assert {:error, %ProviderError{class: :overload}} =
               Exchange.respond(opts, %{request() | remaining_ms: :infinity})

      assert_receive {:fake_request, 2, %{"model" => "gpt-6-luna"}, _at}
      refute_receive {:fake_request, 3, _body, _at}, 100
      refute_received {:recorded, %{event: :model_fallback}}
      FakeResponsesServer.stop(server)
    end
  end

  defp request do
    %Request{
      stage: :develop,
      turn: 1,
      model: "gpt-6-luna",
      effort: "max",
      instructions: "Build it.",
      items: [%{"role" => "user", "content" => []}],
      tool_names: [],
      remaining_ms: 60_000
    }
  end

  defp opts(tmp_dir, url, config_overrides, policy) do
    workdir = Path.join(tmp_dir, "project")
    File.mkdir_p!(workdir)
    test_process = self()

    config =
      Map.merge(
        %ChatGPT.Config{
          access_token: "test-token",
          account_id: "test-account",
          endpoint: url,
          timeout_ms: 30_000
        },
        config_overrides
      )

    %Opts{
      workdir: workdir,
      run_dir: Path.join(tmp_dir, "run"),
      project: %Project{
        root: workdir,
        name: "exchange-resilience-test",
        checks: [],
        setup: [],
        fix: [],
        diagnose: [],
        protected_paths: [],
        domains: %{}
      },
      provider_mod: ChatGPT,
      provider_config: config,
      proc_mod: Kogen.Proc,
      resilience: policy,
      event_recorder: fn event ->
        send(test_process, {:recorded, event})
        :ok
      end
    }
  end
end
