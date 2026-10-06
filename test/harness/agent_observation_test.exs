defmodule Kogen.Harness.AgentObservationTest do
  use Kogen.Testkit.Case

  alias Kogen.Agents
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.RolePrompt
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Provider.ChatGPT
  alias Kogen.Testkit.FakeResponsesServer

  test "an auditor records its provider wait and completed outcome", %{
    tmp_dir: root
  } do
    {url, server} = FakeResponsesServer.start([{:steady, "Done", 10, 50}])
    on_exit(fn -> FakeResponsesServer.stop(server) end)
    project_root = Path.join(root, "project")
    File.mkdir_p!(project_root)

    opts = %Opts{
      workdir: project_root,
      run_dir: Path.join(root, "run"),
      project: %Project{
        root: project_root,
        name: "agent-control",
        checks: [],
        setup: [],
        fix: [],
        diagnose: [],
        protected_paths: [],
        domains: %{}
      },
      provider_mod: ChatGPT,
      provider_config: %ChatGPT.Config{
        access_token: "test-token",
        account_id: "test-account",
        endpoint: url,
        timeout_ms: 30_000
      },
      proc_mod: Kogen.Proc
    }

    task =
      Task.async(fn ->
        Harness.ask(opts, %RolePrompt{
          stage: :audit,
          role: :auditor,
          instructions: "Audit",
          text: "Wait"
        })
      end)

    record = wait_agent(root)
    assert record.role == "auditor"
    assert record.activity == "audit turn 1"
    assert {:ok, %{text: "Done"}} = Task.await(task)
    assert [%{status: "finished", outcome: "finished"}] = Agents.list([Path.join(root, "*")])
  end

  defp wait_agent(root, attempts \\ 100)
  defp wait_agent(_root, 0), do: flunk("agent never entered its provider wait")

  defp wait_agent(root, attempts) do
    case Agents.list([Path.join(root, "*")]) do
      [%{status: "waiting"} = record] ->
        record

      _other ->
        receive do
        after
          20 -> wait_agent(root, attempts - 1)
        end
    end
  end
end
