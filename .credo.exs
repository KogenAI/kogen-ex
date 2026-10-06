%{
  configs: [
    %{
      name: "default",
      strict: true,
      parse_timeout: 30_000,
      files: %{included: ["lib/", "test/"], excluded: [~r"/_build/", ~r"/deps/"]},
      checks: %{
        enabled: [
          # --- stock Warning (correctness/security)
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedMapOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.WrongTestFilename, []},
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          # --- stock Refactor
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]},
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          {Credo.Check.Refactor.FunctionArity, [max_arity: 6]},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Design.TagFIXME, []},
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Consistency.ExceptionNames, []},
          # --- custom (prototypes)
          {KogenChecks.Check.ForbiddenCall,
           [
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
                 allow: [
                   "lib/kogen/kernel/",
                   "lib/kogen/proc/sandbox.ex",
                   "test/support/testkit/temp.ex"
                 ]
               }
             ]
           ]},
          {KogenChecks.Check.CtxBag,
           [
             banned_names: [:ctx, :context],
             allowed_names: [:conn, :socket],
             min_clauses: 4,
             min_passed_ratio: 0.5,
             min_fields: 8,
             min_ambient: 2,
             ambient_fields:
               ~w(root cwd dir env tmp_dir tmp now clock time runner proc cmd git io shell config opts options control state log log_path logger harness provider http client repo context ctx timeout deadline registry store cache runtime deps services)a,
             included_paths: ["lib/"]
           ]},
          {KogenChecks.Check.StringKeyAccess,
           [
             included_paths: ["lib/"],
             codec_modules: [
               Kogen.Quality.Codec,
               Kogen.Quality.Request,
               Kogen.Contracts.Yaml,
               Kogen.Contracts.StreamProgress,
               Kogen.Resilience.Recovery,
               Kogen.Contracts.GateTiming.Codec,
               Kogen.Intent.Parser.Scheduling,
               Kogen.Contracts.ShapeWarningCodec,
               Kogen.Proc.Request,
               Kogen.Project.Loader,
               Kogen.Intent.ShapingCodec,
               Kogen.CheckLearning.Codec,
               Kogen.Project.BuildSettings,
               Kogen.Workspace.Git,
               Kogen.Contracts.MiseEnvironment,
               Kogen.Engine.Runtime,
               Kogen.Engine.RailsEnvironment,
               Kogen.Provider.ChatGPT.Codec,
               Kogen.Provider.ChatGPT.Codec.Recording,
               Kogen.Provider.ChatGPT.Callback,
               Kogen.Provider.ChatGPT.CredentialStore,
               Kogen.Provider.ChatGPT.HostId,
               Kogen.Provider.ChatGPT.IDToken,
               Kogen.Provider.ChatGPT.OIDC,
               Kogen.Provider.ChatGPT.Refresh.Codec,
               Kogen.Provider.ChatGPT.SIWC.TokenResponse,
               Kogen.Agents.Codec,
               Kogen.ResponseProtocol.Codec,
               Kogen.Harness.Codec,
               Kogen.Conversation,
               Kogen.Tooling.Codec,
               Kogen.Checks.Ledger,
               Kogen.State.ApprovalBaselineCodec,
               Kogen.State.Json,
               Kogen.State.Flakes.Codec,
               Kogen.Kernel.CLI.ShapeJson,
               Kogen.Runner.Auditor
             ]
           ]},
          {KogenChecks.Check.FailOpenWith, [included_paths: ["lib/"]]},
          {KogenChecks.Check.SizeLimits,
           [max_file_lines: 400, max_module_lines: 400, max_function_lines: 40]},
          {KogenChecks.Check.TestModuleShape, [max_tests: 30, serial_allowed: []]},
          {KogenChecks.Check.DomainReach,
           [
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
               Kogen.Cli => [],
               Kogen.Workspace => [Kogen.Proc],
               Kogen.Provider => [Kogen.Http, Kogen.Proc, Kogen.ResponseProtocol],
               Kogen.ResponseProtocol => [],
               Kogen.State => [Kogen.Workspace],
               Kogen.CheckLearning => [Kogen.Proc, Kogen.State, Kogen.Workspace],
               Kogen.Shaping => [Kogen.Workspace, Kogen.State],
               Kogen.Quality => [Kogen.Proc, Kogen.Workspace],
               Kogen.Diagnostics => [],
               Kogen.Checks => [
                 Kogen.Quality,
                 Kogen.Diagnostics,
                 Kogen.Proc,
                 Kogen.Workspace,
                 Kogen.Project
               ],
               Kogen.Flakes => [Kogen.Checks, Kogen.Workspace],
               Kogen.Agents => [],
               Kogen.Harness => [
                 Kogen.Agents,
                 Kogen.Flakes,
                 Kogen.Conversation,
                 Kogen.Quality,
                 Kogen.Checks,
                 Kogen.Proc,
                 Kogen.Provider,
                 Kogen.Project,
                 Kogen.Resilience,
                 Kogen.Tooling
               ],
               Kogen.Conversation => [],
               Kogen.Resilience => [],
               Kogen.Build => [Kogen.Resilience],
               Kogen.Tooling => [Kogen.Proc, Kogen.Resilience],
               Kogen.Queue => [Kogen.Intent, Kogen.Proc, Kogen.State, Kogen.Workspace],
               Kogen.Runner => [
                 Kogen.Build,
                 Kogen.Checks,
                 Kogen.Engine,
                 Kogen.Harness,
                 Kogen.State
               ],
               Kogen.Engine => [
                 Kogen.CheckLearning,
                 Kogen.Shaping,
                 Kogen.Proc,
                 Kogen.Project,
                 Kogen.Intent,
                 Kogen.Provider,
                 Kogen.Build,
                 Kogen.Workspace,
                 Kogen.State,
                 Kogen.Checks,
                 Kogen.Harness,
                 Kogen.Resilience
               ],
               Kogen.Kernel => [
                 Kogen.Agents,
                 Kogen.CheckLearning,
                 Kogen.Shaping,
                 Kogen.Proc,
                 Kogen.Project,
                 Kogen.Intent,
                 Kogen.Provider,
                 Kogen.Engine,
                 Kogen.Workspace,
                 Kogen.State,
                 Kogen.Checks,
                 Kogen.Harness,
                 Kogen.Resilience,
                 Kogen.Shaper,
                 Kogen.Queue,
                 Kogen.Runner,
                 Kogen.Cli
               ],
               Kogen.E2e => [
                 Kogen.Engine,
                 Kogen.Kernel,
                 Kogen.Proc,
                 Kogen.Project,
                 Kogen.Queue,
                 Kogen.Resilience,
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
                 Kogen.Project,
                 Kogen.Resilience
               ]
             },
             root: Kogen,
             shared: [Kogen.Contracts],
             also_allowed: [Kogen.Testkit]
           ]},
          {KogenChecks.Check.DomainSize, [max_lines: 3000]},
          {KogenChecks.Check.MissingExternalResource, [blocking: true]},
          {KogenChecks.Check.RepeatedMapShape, []},
          {KogenChecks.Check.BroadRescue, []}
        ],
        disabled: []
      }
    }
  ]
}
