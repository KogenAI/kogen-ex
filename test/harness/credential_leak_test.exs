defmodule Kogen.Harness.CredentialLeakTest.CrashingProvider do
  @moduledoc false
  # Stands in for an HTTP client whose handler dies mid-request: the linked handler holds the
  # request, bearer included, and stops abnormally with the request in its exit reason.
  @behaviour Kogen.Contracts.ProviderPort

  use GenServer

  alias Kogen.Contracts.ModelResponse

  @impl Kogen.Contracts.ProviderPort
  def respond(%{calls: calls, token: token}, _request) do
    if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
      request = %{headers: [{"authorization", "Bearer " <> token}], body: "{}"}
      {:ok, handler} = GenServer.start_link(__MODULE__, request)
      GenServer.cast(handler, :crash)

      receive do
      after
        5_000 -> {:ok, response()}
      end
    else
      {:ok, response()}
    end
  end

  @impl GenServer
  def init(request), do: {:ok, request}

  @impl GenServer
  def handle_cast(:crash, request), do: {:stop, {:request_failed, request}, request}

  defp response do
    usage = %{input: 1, cached_input: 0, cache_write: 0, output: 1, reasoning: 0}

    %ModelResponse{
      id: "recovered",
      text: "recovered",
      tool_calls: [],
      usage: usage,
      raw_items: []
    }
  end
end

defmodule Kogen.Harness.CredentialLeakTest do
  use Kogen.Testkit.Case

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ProviderError
  alias Kogen.Contracts.Redact
  alias Kogen.Harness.CredentialLeakTest.CrashingProvider
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request
  alias Kogen.Harness.Opts
  alias Kogen.Provider.ChatGPT
  alias Kogen.Resilience.Policy

  # A fake credential shaped like a real ChatGPT access token.
  @token "eyJhbGciOiJSUzI1NiJ9." <> String.duplicate("fAkEpAyLoAd", 6) <> ".c2lnbmF0dXJl"
  @fast %Policy{backoff_base_ms: 10, backoff_max_ms: 20}

  setup do
    :ok = Redact.install_log_filter()
  end

  test "a request stopped mid-flight on its cap leaks the bearer nowhere", %{tmp_dir: tmp_dir} do
    {proxy, listener} = hanging_proxy()

    config = %ChatGPT.Config{
      access_token: @token,
      account_id: "fake-account",
      endpoint: "https://chatgpt.invalid/backend-api/codex/responses",
      timeout_ms: 30_000,
      proxy_env: %{"https_proxy" => proxy}
    }

    opts = opts(tmp_dir, ChatGPT, config, %{@fast | request_cap_ms: 300})

    output =
      leak_surface(fn ->
        assert {:error, %ProviderError{class: :timeout}} =
                 Exchange.respond(opts, %{request() | remaining_ms: 1_200})
      end)

    :gen_tcp.close(listener)
    refute_leak(output <> journals(opts))
  end

  test "a provider handler that crashes mid-request is retried as a transport error", %{
    tmp_dir: tmp_dir
  } do
    calls = start_supervised!({Agent, fn -> 0 end})
    opts = opts(tmp_dir, CrashingProvider, %{calls: calls, token: @token}, @fast)

    output =
      leak_surface(fn ->
        assert {:ok, %{text: "recovered"}} = Exchange.respond(opts, request())
      end)

    assert_receive {:recorded, %{event: :provider_retry, reason: :transport} = retry}
    transcript = journals(opts)
    assert transcript =~ "Provider process failed: request_failed"
    refute_leak(output <> inspect(retry) <> transcript)
  end

  # Everything a person or model could read: stdout, stderr and every log event.
  defp leak_surface(fun) do
    log =
      capture_log(fn ->
        stderr = capture_io(:stderr, fn -> send(self(), {:stdout, capture_io(fun)}) end)
        send(self(), {:stderr, stderr})
        # OTP logs a crash report after the crashed process is gone.
        receive do
        after
          300 -> :ok
        end
      end)

    assert_received {:stdout, stdout}
    assert_received {:stderr, stderr}
    Enum.join([log, stdout, stderr], "\n")
  end

  defp journals(opts) do
    Enum.map_join(
      ["transcript.jsonl", "requests.jsonl"],
      "\n",
      &File.read!(Path.join(opts.run_dir, &1))
    )
  end

  defp refute_leak(text) do
    refute text =~ @token
    refute text =~ String.slice(@token, 21, 30)
    refute text =~ "State:"
  end

  # Accepts the client's CONNECT and never answers, so the request stalls mid-flight.
  defp hanging_proxy do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    spawn_link(fn -> hold(listener, []) end)
    {"http://127.0.0.1:#{port}", listener}
  end

  defp hold(listener, sockets) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} -> hold(listener, [socket | sockets])
      {:error, _closed} -> :ok
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

  defp opts(tmp_dir, provider_mod, provider_config, policy) do
    workdir = Path.join(tmp_dir, "project")
    File.mkdir_p!(workdir)
    test_process = self()

    %Opts{
      workdir: workdir,
      run_dir: Path.join(tmp_dir, "run"),
      project: %Project{
        root: workdir,
        name: "credential-leak-test",
        checks: [],
        setup: [],
        fix: [],
        diagnose: [],
        protected_paths: [],
        domains: %{}
      },
      provider_mod: provider_mod,
      provider_config: provider_config,
      proc_mod: Kogen.Proc,
      resilience: policy,
      event_recorder: fn event ->
        send(test_process, {:recorded, event})
        :ok
      end
    }
  end
end
