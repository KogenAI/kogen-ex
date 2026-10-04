defmodule KogenChecks.GateWiringTest do
  use ExUnit.Case, async: true

  @credo_path Path.expand("../../../.credo.exs", __DIR__)
  @required_checks %{
    KogenChecks.Check.BroadRescue => [],
    KogenChecks.Check.CtxBag => [
      banned_names: [:ctx, :context],
      allowed_names: [:conn, :socket],
      min_clauses: 4,
      min_passed_ratio: 0.5,
      min_fields: 8,
      min_ambient: 2,
      ambient_fields:
        ~w(root cwd dir env tmp_dir tmp now clock time runner proc cmd git io shell config opts options control state log log_path logger harness provider http client repo context ctx timeout deadline registry store cache runtime deps services)a,
      included_paths: ["lib/"]
    ],
    KogenChecks.Check.DomainReach => [
      dependencies: %{
        Kogen.Acceptance => [
          Kogen.Proc,
          Kogen.Project,
          Kogen.Intent,
          Kogen.Provider,
          Kogen.Build,
          Kogen.Engine,
          Kogen.Workspace,
          Kogen.State,
          Kogen.Checks,
          Kogen.Harness,
          Kogen.Kernel,
          Kogen.E2e
        ],
        Kogen.Project => [Kogen.Workspace],
        Kogen.Workspace => [Kogen.Proc],
        Kogen.Provider => [Kogen.Http, Kogen.Proc],
        Kogen.State => [Kogen.Workspace],
        Kogen.Checks => [Kogen.Proc, Kogen.Workspace, Kogen.Project],
        Kogen.Harness => [
          Kogen.Checks,
          Kogen.Proc,
          Kogen.Provider,
          Kogen.Project,
          Kogen.Tooling
        ],
        Kogen.Tooling => [Kogen.Proc],
        Kogen.Engine => [
          Kogen.Proc,
          Kogen.Project,
          Kogen.Intent,
          Kogen.Provider,
          Kogen.Build,
          Kogen.Workspace,
          Kogen.State,
          Kogen.Checks,
          Kogen.Harness
        ],
        Kogen.Kernel => [
          Kogen.Proc,
          Kogen.Project,
          Kogen.Intent,
          Kogen.Provider,
          Kogen.Engine,
          Kogen.Workspace,
          Kogen.State,
          Kogen.Checks,
          Kogen.Harness
        ],
        Kogen.E2e => [
          Kogen.Engine,
          Kogen.Kernel,
          Kogen.Proc,
          Kogen.Project,
          Kogen.Shaper,
          Kogen.State,
          Kogen.Testkit,
          Kogen.Workspace
        ],
        Kogen.Shaper => [
          Kogen.Contracts,
          Kogen.Checks,
          Kogen.Harness,
          Kogen.Intent,
          Kogen.Kernel,
          Kogen.E2e,
          Kogen.Proc,
          Kogen.Project
        ]
      },
      root: Kogen,
      shared: [Kogen.Contracts],
      also_allowed: [Kogen.Testkit]
    ],
    KogenChecks.Check.DomainSize => [max_lines: 3000],
    KogenChecks.Check.FailOpenWith => [included_paths: ["lib/"]],
    KogenChecks.Check.ForbiddenCall => [
      rules: [
        %{
          calls: [
            {File, :cd!},
            {File, :cd},
            {System, :put_env},
            {System, :delete_env},
            {Application, :put_env}
          ],
          message: "Pass explicit values instead of mutating process-global state.",
          allow: []
        },
        %{
          calls: [{Process, :sleep}, {:timer, :sleep}],
          message: "Wait on a message (assert_receive) or the injected clock.",
          allow: []
        },
        %{
          calls: [{System, :cmd}, {System, :shell}, {Port, :open}, {:os, :cmd}],
          message: "Spawn through the Proc port (own group, wall deadline, TERM->KILL).",
          allow: [
            "lib/kogen/proc/",
            "lib/kogen/proc.ex",
            "test/support/testkit/proc.ex",
            "test/support/testkit/git.ex"
          ]
        },
        %{
          calls: [
            {System, :get_env},
            {System, :fetch_env!},
            {System, :fetch_env},
            {System, :user_home},
            {System, :user_home!},
            {System, :tmp_dir!},
            {File, :cwd!},
            {File, :cwd},
            {DateTime, :utc_now},
            {System, :os_time}
          ],
          message: "Pass explicit values; read ambient configuration in Kogen.Kernel.",
          allow: ["lib/kogen/kernel/", "test/support/testkit/temp.ex"]
        }
      ]
    ],
    KogenChecks.Check.SizeLimits => [
      max_file_lines: 400,
      max_module_lines: 400,
      max_function_lines: 40
    ],
    KogenChecks.Check.StringKeyAccess => [
      included_paths: ["lib/"],
      codec_modules: [
        Kogen.Contracts.Yaml,
        Kogen.Contracts.ShapeWarningCodec,
        Kogen.Proc.Request,
        Kogen.Project.Loader,
        Kogen.Workspace.Git,
        Kogen.Contracts.MiseEnvironment,
        Kogen.Engine.Runtime,
        Kogen.Provider.ChatGPT.Codec,
        Kogen.Provider.ChatGPT.Codec.Recording,
        Kogen.Provider.ChatGPT.Callback,
        Kogen.Provider.ChatGPT.CredentialStore,
        Kogen.Provider.ChatGPT.HostId,
        Kogen.Provider.ChatGPT.IDToken,
        Kogen.Provider.ChatGPT.OIDC,
        Kogen.Provider.ChatGPT.Refresh.Codec,
        Kogen.Provider.ChatGPT.SIWC.TokenResponse,
        Kogen.Provider.ChatGPT.SIWCCCodec,
        Kogen.Harness.Codec,
        Kogen.Tooling.Codec,
        Kogen.Checks.Ledger,
        Kogen.State.Json,
        Kogen.Kernel.CLI.ShapeJson
      ]
    ],
    KogenChecks.Check.TestModuleShape => [max_tests: 30, serial_allowed: []]
  }

  test "every required check is enabled with the exact protected parameters" do
    {:ok, _started_apps} = Application.ensure_all_started(:credo)
    parent = self()

    Credo.CLI.Output.Shell.suppress_output(fn ->
      send(parent, {:execution, Credo.run(["info", "--config-file", @credo_path])})
    end)

    assert_received {:execution, execution}
    {enabled, _only, _ignored} = Credo.Execution.checks(execution)
    enabled_checks = Map.new(enabled)

    assert map_size(enabled_checks) == length(enabled), "duplicate checks are not allowed"

    Enum.each(@required_checks, fn {check, params} ->
      assert Map.fetch(enabled_checks, check) == {:ok, params},
             "#{inspect(check)} is missing or has changed parameters"
    end)
  end
end
