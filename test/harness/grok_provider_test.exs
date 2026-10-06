defmodule Kogen.Harness.GrokProviderTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.RolePrompt
  alias Kogen.Conversation.PromptCacheKey
  alias Kogen.Grok
  alias Kogen.Grok.Codec
  alias Kogen.Grok.CredentialStore
  alias Kogen.Grok.DeviceAuth
  alias Kogen.Grok.Refresh
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Resilience.Policy
  alias Kogen.Testkit.FakeOAuthServer
  alias Kogen.Testkit.FakeResponsesServer

  test "device login, refresh, streamed tools, stable affinity and cached usage use only fake servers",
       %{tmp_dir: tmp_dir} do
    owner = self()

    {oauth_server, oauth_port, oauth_requests, _poll_count, _port_agent} =
      start_oauth_server(owner)

    on_exit(fn ->
      FakeOAuthServer.stop({oauth_server, oauth_port, oauth_requests})
    end)

    oauth_url = "http://127.0.0.1:#{oauth_port}"
    token_endpoint = oauth_url <> "/oauth2/token"

    api_items = [
      {:items, [tool_call_item()], usage(120, 25, 18, 7)},
      {:items, [message_item("tool result received")], usage(140, 30, 21, 9)},
      {:items, [message_item("journal entry one")], usage(80, 8, 12, 2)},
      {:items, [message_item("journal entry two")], usage(92, 11, 15, 3)}
    ]

    {responses_url, response_server} = FakeResponsesServer.start(api_items)
    on_exit(fn -> FakeResponsesServer.stop(response_server) end)

    root = Path.join(tmp_dir, ".kogen")
    displayed = self()

    assert {:ok, %{label: "default", email: "fake@example.test"}} =
             DeviceAuth.login(root, :file, "default",
               issuer: oauth_url,
               discovery_url: oauth_url <> "/.well-known/openid-configuration",
               proxy_env: %{},
               allow_insecure_http: true,
               wait: fn _milliseconds -> :ok end,
               show_device: fn device ->
                 send(displayed, {:device_code, device.user_code, device.verification_uri})
                 :ok
               end
             )

    assert_receive {:device_code, "ABCD-EFGH", "https://accounts.x.ai/device?code=ABCD-EFGH"}
    assert {:ok, credentials} = CredentialStore.load(root, :file, "default")
    assert credentials.access_token == "access-1"
    assert credentials.refresh_token == "refresh-1"

    assert {:ok, refreshed} =
             Refresh.access_token(root, :file, "default",
               token_endpoint: token_endpoint,
               proxy_env: %{}
             )

    assert refreshed.access_token == "access-2"
    assert refreshed.refresh_token == "refresh-2"

    assert {:ok, config} =
             Grok.owned_config(root, :file, "default",
               endpoint: responses_url,
               token_endpoint: token_endpoint,
               proxy_env: %{}
             )

    run_dir = Path.join(tmp_dir, "run")
    affinity = PromptCacheKey.for_run_stage(run_dir, :develop)
    request = model_request(affinity, [user_item("call a tool")], [tool_spec()])
    assert {:ok, first_body} = Codec.encode_request(request)

    assert {:ok, response} = Grok.respond(config, request)
    assert response.text == ""

    assert [%{id: "call-1", name: "echo_phrase", arguments: %{"phrase" => "cached"}}] =
             response.tool_calls

    next_request =
      model_request(
        affinity,
        [
          user_item("call a tool"),
          tool_call_item(),
          %{"type" => "function_call_output", "call_id" => "call-1", "output" => "done"}
        ],
        [tool_spec()]
      )

    assert {:ok, next_body} = Codec.encode_request(next_request)
    assert_wire_prefix(first_body, next_body)

    assert {:ok, next_response} = Grok.respond(config, next_request)
    assert next_response.text == "tool result received"
    assert next_response.usage == %{input: 110, cached_input: 30, output: 21, reasoning: 9}

    workdir = Path.join(tmp_dir, "project")
    File.mkdir_p!(workdir)

    project = %Project{
      root: workdir,
      name: "grok-fixture",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{}
    }

    opts = %Opts{
      workdir: workdir,
      run_dir: run_dir,
      project: project,
      provider_mod: Grok,
      provider_config: config,
      proc_mod: Kogen.Proc,
      resilience: %Policy{backoff_base_ms: 0, backoff_max_ms: 0},
      models: %{builder: {"grok-4.6", "high"}, strong: {"grok-4.6", "high"}},
      limits: %{max_turns: 4, wall_ms: 20_000}
    }

    prompt = %RolePrompt{
      stage: :develop,
      role: :builder,
      instructions: "Answer briefly.",
      text: "one"
    }

    assert {:ok, %{usage: %{cached_input: 8}}} = Harness.ask(opts, prompt)
    assert {:ok, %{usage: %{cached_input: 11}}} = Harness.ask(opts, %{prompt | text: "two"})

    requests = Enum.map(1..4, fn _ -> receive_request!() end)
    headers = Enum.map(1..4, fn _ -> receive_headers!() end)

    assert Enum.map(Enum.take(requests, 2), & &1["prompt_cache_key"]) == [affinity, affinity]
    assert Enum.map(Enum.drop(requests, 2), & &1["prompt_cache_key"]) == [affinity, affinity]
    assert Enum.map(headers, &Map.get(&1, "x-grok-conv-id")) == List.duplicate(affinity, 4)
    assert Enum.map(headers, &Map.get(&1, "x-grok-session-id")) == List.duplicate(affinity, 4)
    assert Enum.all?(headers, &(Map.get(&1, "authorization") == "Bearer access-2"))
    assert Enum.all?(headers, &(Map.get(&1, "x-xai-token-auth") == "xai-grok-cli"))
    assert Enum.all?(headers, &(Map.get(&1, "x-authenticateresponse") == "authenticate-response"))
    assert Enum.all?(headers, &Regex.match?(~r/\A[0-9a-f-]{36}\z/i, &1["x-grok-req-id"]))
    assert length(Enum.uniq(Enum.map(headers, & &1["x-grok-req-id"]))) == 4
    assert Enum.all?(requests, &(&1["model"] == "grok-4.6" and &1["stream"] == true))

    journal =
      run_dir
      |> Path.join("requests.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)

    assert length(journal) == 2
    assert Enum.map(journal, &get_in(&1, ["tokens", "cached_input"])) == [8, 11]

    assert_received {:xai_oauth_request, %{path: "/.well-known/openid-configuration"}}
    assert_received {:xai_oauth_request, %{path: "/oauth2/device/code", form: device_form}}
    assert device_form["client_id"] == "b1a00492-073a-47ea-816f-4c329264a828"
    assert device_form["scope"] =~ "grok-cli:access"

    assert_received {:xai_oauth_request,
                     %{path: "/oauth2/token", form: %{"device_code" => "device-1"}}}

    assert_received {:xai_oauth_request,
                     %{path: "/oauth2/token", form: %{"device_code" => "device-1"}}}

    assert_received {:xai_oauth_request,
                     %{
                       path: "/oauth2/token",
                       form: %{"grant_type" => "refresh_token", "refresh_token" => "refresh-1"}
                     }}
  end

  defp start_oauth_server(owner) do
    {:ok, poll_count} = Agent.start_link(fn -> 0 end)
    {:ok, port_agent} = Agent.start_link(fn -> nil end)
    {server, port, requests} = FakeOAuthServer.start(oauth_handler(owner, poll_count, port_agent))
    Agent.update(port_agent, fn _previous -> port end)
    {server, port, requests, poll_count, port_agent}
  end

  defp oauth_handler(owner, poll_count, port_agent) do
    fn request ->
      send(owner, {:xai_oauth_request, request})
      port = Agent.get(port_agent, & &1)
      oauth_response(request, port, poll_count)
    end
  end

  defp oauth_response(%{path: "/.well-known/openid-configuration"}, port, _poll_count) do
    {200,
     encode(%{
       "issuer" => "http://127.0.0.1:#{port}",
       "device_authorization_endpoint" => "http://127.0.0.1:#{port}/oauth2/device/code",
       "token_endpoint" => "http://127.0.0.1:#{port}/oauth2/token"
     })}
  end

  defp oauth_response(%{path: "/oauth2/device/code"}, _port, _poll_count) do
    {200,
     encode(%{
       "device_code" => "device-1",
       "user_code" => "ABCD-EFGH",
       "verification_uri" => "https://accounts.x.ai/device",
       "verification_uri_complete" => "https://accounts.x.ai/device?code=ABCD-EFGH",
       "expires_in" => 60,
       "interval" => 0
     })}
  end

  defp oauth_response(%{path: "/oauth2/token", form: form}, _port, poll_count),
    do: token_response(form, poll_count)

  defp oauth_response(_request, _port, _poll_count), do: {404, encode(%{"error" => "not_found"})}

  defp token_response(
         %{"grant_type" => "urn:ietf:params:oauth:grant-type:device_code"},
         poll_count
       ) do
    case Agent.get_and_update(poll_count, fn count -> {count, count + 1} end) do
      0 -> {400, encode(%{"error" => "authorization_pending"})}
      _count -> {200, encode(device_token())}
    end
  end

  defp token_response(
         %{"grant_type" => "refresh_token", "refresh_token" => "refresh-1"},
         _poll_count
       ) do
    {200,
     encode(%{
       "access_token" => "access-2",
       "refresh_token" => "refresh-2",
       "expires_in" => 3600
     })}
  end

  defp token_response(other, _poll_count),
    do: {400, encode(%{"error" => "unexpected_request", "received" => inspect(other)})}

  defp device_token do
    %{
      "access_token" => "access-1",
      "refresh_token" => "refresh-1",
      "expires_in" => 1,
      "scope" => "openid profile email offline_access grok-cli:access api:access",
      "email" => "fake@example.test"
    }
  end

  defp model_request(cache_key, input, tools) do
    %ModelRequest{
      model: "grok-4.6",
      effort: "high",
      instructions: "Use the tool and report the result.",
      input: input,
      tools: tools,
      previous_response_id: nil,
      prompt_cache_key: cache_key
    }
  end

  defp tool_spec do
    %{
      "type" => "function",
      "name" => "echo_phrase",
      "description" => "Echo a phrase.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"phrase" => %{"type" => "string"}},
        "required" => ["phrase"],
        "additionalProperties" => false
      }
    }
  end

  defp tool_call_item do
    %{
      "id" => "fc-1",
      "type" => "function_call",
      "call_id" => "call-1",
      "name" => "echo_phrase",
      "arguments" => ~s({"phrase":"cached"})
    }
  end

  defp message_item(text),
    do: %{
      "id" => "msg-#{text}",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }

  defp user_item(text),
    do: %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}

  defp usage(input, cached, output, reasoning) do
    %{
      "input_tokens" => input,
      "input_tokens_details" => %{"cached_tokens" => cached},
      "output_tokens" => output,
      "output_tokens_details" => %{"reasoning_tokens" => reasoning}
    }
  end

  defp receive_request! do
    assert_receive {:fake_request, _index, body, _at}, 10_000
    body
  end

  defp receive_headers! do
    assert_receive {:fake_request_headers, _index, headers}, 10_000
    headers
  end

  defp assert_wire_prefix(before_bytes, after_bytes) do
    assert String.ends_with?(before_bytes, "]}")
    prefix = binary_part(before_bytes, 0, byte_size(before_bytes) - 2)
    assert String.starts_with?(after_bytes, prefix)
    assert binary_part(before_bytes, byte_size(prefix), 1) == "]"
    assert binary_part(after_bytes, byte_size(prefix), 1) == ","
  end

  defp encode(value), do: value |> :json.encode() |> IO.iodata_to_binary()
end
