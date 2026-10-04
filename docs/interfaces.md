# Kogen P0 interfaces (authoritative)

This file is the contract between domains. Change it only through the integrator. Types refer to `Kogen.Contracts.*` structs unless stated. Paths are absolute strings. Only `Kogen.Kernel` reads HOME, env or cwd; everyone else receives explicit values.

## Dependency graph (Boundary, acyclic)
`contracts` ← every domain. `workspace` → proc. `provider` → proc. `state` → workspace. `checks` → proc, workspace, project. `harness` → proc, provider, project. `build` is pure (contracts only). `shaper` → checks, harness, intent, proc, project. `engine` → build, intent, proc, project, provider, workspace, state, checks, harness. `kernel` → proc, project, intent, provider, engine, workspace, state, checks, harness, shaper.

## Kogen.Proc
- `run([String.t()], opts) :: {:ok, ProcResult.t()} | {:error, :enoent | term()}`
  - `cd:` required
  - `env:` %{String => String}, merged onto an allowlist (PATH, HOME, LANG, LC_ALL, TERM, TMPDIR, USER, SHELL, MIX_HOME, HEX_HOME, MISE_*, GIT_*)
  - `timeout_ms:` default 120_000
  - `log_path:` optional
  - `stdin:` `nil` | `{:binary, iodata}` | `{:file, path}`
  - `sandbox:` optional `%Kogen.Proc.Sandbox{}` for commands that execute Candidate code
- A non-zero exit is `{:ok, %ProcResult{exit_status: n}}`, not an error. A timeout is `{:ok, %ProcResult{timed_out: true, exit_status: nil}}`.

## Kogen.Workspace (git through Kogen.Proc; every function takes explicit repo paths and a `git_env` map)
- `create(origin, base_sha, workspace_root, build_id, git_env, options \\ []) :: {:ok, %{path: String.t(), base_sha: String.t()}} | {:error, term()}`: clone without hardlinks into `<workspace_root>/<build_id>` and check out `base_sha` detached. Kernel derives `<workspace_root>` as `~/.kogen/workspaces/<project-key>` from the absolute project path; the key is its readable basename plus a short SHA-256 suffix. `options` may contain `seed_from:`; deps/_build are copied from that checkout (or origin by default) with `cp -c -R`.
- `insert_files(path, %{dest_rel_path => binary}) :: :ok`
- `tree_hash(path, git_env) :: {:ok, sha}`: includes untracked, non-ignored files; private index.
- `diff(path, base_sha, git_env) :: {:ok, binary()}`: full diff of the Candidate's working tree against `base_sha`, including untracked, non-ignored files; materializes through a private index and does not modify the real index.
- `changed_paths(path, base_sha, git_env) :: {:ok, [rel_path]}`
- `commit(path, message, trailers :: [{key, value}], git_env) :: {:ok, sha}`: `git add -A` + `git commit`. Candidate Git calls temporarily remove `.git/config` and `.git/info/exclude`, apply `core.hooksPath=/dev/null`, `core.fsmonitor=false`, and `core.excludesFile=/dev/null` with `-c`, then restore metadata. This prevents local hooks, filters, fsmonitor, excludes, and signing overrides from steering the judge. Global signing config remains in effect; tests disable signing via git_env.
- `reset_soft(path, base_sha, git_env) :: :ok | {:error, term()}`: move Candidate HEAD to the approved base while preserving staged changes.
- `rebase(path, origin, base_sha, git_env) :: :ok | {:error, term()}`: fetch the specified base commit from `origin` and rebase the Candidate onto it.
- `land(path, origin, branch, expected_old_sha, run_id, git_env) :: :ok | {:error, :base_moved | :ref_locked | :not_fast_forward | term()}`: push HEAD to `refs/kogen/incoming/<run_id>`, CAS `refs/heads/<branch>`, delete the temp ref. Requires HEAD's sole parent == expected_old_sha.
- `park(path, origin, run_id, git_env) :: :ok`: pushes HEAD to `refs/kogen/parked/<run_id>`.
- `destroy(path) :: :ok`
- Ref helpers (`repo`, `git_env` first):
  - `ref_read(repo, ref, git_env) :: {:ok, sha} | {:error, :missing}`
  - `ref_create(repo, ref, sha, git_env) :: :ok | {:error, :exists}`
  - `ref_update(repo, ref, new, old, git_env) :: :ok | {:error, :stale}`
  - `ref_delete(repo, ref, expected, git_env) :: :ok | {:error, :stale}`
  - `commit_tree_with_files(repo, %{rel_path => binary}, parents, message, git_env) :: {:ok, sha}`
  - `read_file_at(repo, rev, path, git_env) :: {:ok, binary} | {:error, :missing}`
  - `commit_message(repo, rev, git_env) :: {:ok, binary}`
  - `rev_parse(repo, rev, git_env) :: {:ok, sha} | {:error, :missing}`
  - `ancestor?(repo, a, b, git_env) :: boolean()`

## Kogen.Intent / Kogen.Project
- `Kogen.Intent.parse(path) :: {:ok, Intent.t()} | {:error, [%{line: pos_integer(), message: String.t()}]}`
- `Kogen.Intent.parse_binary(binary, path) :: same`
- `Kogen.Intent.lint(Intent.t()) :: [%{rule: atom(), message: String.t(), line: pos_integer() | nil}]`
- `Kogen.Intent.hash(binary) :: String.t()` (sha256 hex)
- `Kogen.Project.load(checkout_root) :: {:ok, Project.t()} | {:error, [%{line, message}]}`, reading `.kogen/project.yaml`
- Intent files live at `.kogen/intents/<slug>/intent.md`; `parse/1` derives `<slug>` from the parent directory.
- Acceptance test files live at `.kogen/acceptance/<slug>_test.exs` in the checkout, and are installed into the Candidate at `test/acceptance/<slug>_test.exs`.
- `.kogen/project.yaml` may declare `format: [argv...]` beside `checks:` and `setup:`. Shaping appends the generated source paths to this argv. If omitted, it derives the formatter from the first `checks:` argv containing both `format` and `--check-formatted`, removing the latter flag; otherwise it uses `mix format`. If the formatter is missing (`:enoent` or exit 127), shaping records a warning and continues to the acceptance checks; those checks still run normally.
- `.kogen/project.yaml` may declare `setup_outputs: [relative, paths]` to reuse successful setup output across shaping, approval, and Build. The cache key includes the base Git tree, setup specs and project env, plus the resolved toolchain identity. Omitted or empty outputs preserve setup execution without caching.

## Kogen.Provider
- `Kogen.Provider.ChatGPT.config(auth_path) :: {:ok, %Kogen.Provider.ChatGPT.Config{}} | {:error, ProviderError.t()}`
- `owned_config(root, :file | :keychain, label)` uses Kogen's saved ChatGPT plan credential; `borrowed_codex_config(path)` is only selected by the explicit `--borrow codex` option.
- Kogen-owned requests use `https://api.openai.com/v1/responses`; refresh tokens are rotated under a cross-process lock. Linux stores credentials in a 0600 file. macOS encrypts credentials with AES-256-GCM into `~/.kogen/credentials/chatgpt-<label>.enc` and stores the base64 32-byte key under Keychain service `kogen`, account `chatgpt:<label>:key`; old base64 credentials under `chatgpt:<label>` remain readable and migrate on save.
- `respond(config, ModelRequest.t()) :: {:ok, ModelResponse.t()} | {:error, ProviderError.t()}` (the ProviderPort behaviour is `respond(term(), ModelRequest.t())`)
- `Kogen.Provider.Fake.config(fixture_paths)` with the same `respond/2`.
- `ModelResponse.raw_items` = the full ordered output items. The harness sends them back with `function_call_output` items `{type: "function_call_output", call_id, output}`.

## Kogen.Harness
- `context_pack(%Kogen.Harness.Opts{}, intent_text) :: {:ok, %Kogen.Harness.Pack{text, refs, usage}} | {:error, term()}`
- `shape(%Opts{}, slug, task, history, failure_text, turn_offset) :: {:ok, %ShapePass{items, text, calls, turns}} | {:error, term()}`; the stage exposes read/search and writes only the two slug-specific generated files.
- `plan(%Opts{}, pack, intent_text) :: {:ok, %Kogen.Harness.Plan{text, usage}} | {:error, term()}`
- `develop(%Opts{}, intent_text, plan | nil, resume :: nil | %{previous_items: list(), failure_text: String.t()}) :: {:ok, %Kogen.Harness.Result{outcome: :done | :gate_red | :gave_up, gate: map() | nil, items: list(), turns, usage, transcript_path}} | {:error, term()}`
- `review(%Opts{}, intent_text, diff, check_summary) :: {:ok, %Kogen.Harness.Review{verdict: :accept | :revise, findings: [String.t()], usage}} | {:error, term()}`
- `%Kogen.Harness.Opts{}` fields:
  - `workdir`, `run_dir`, `project`, `sandbox`
  - `provider_mod`, `provider_config`
  - `proc_mod`
  - `models` (`%{builder: {"gpt-6-luna", "max"}, strong: {"gpt-6.1-sol", "high"}}`)
  - `limits` (`%{max_turns: 60, wall_ms: 1_800_000}`)
  - `before_gate` optional zero-arity callback; Kernel uses it to check the approval protected manifest and scope before the done gate runs a fixer or check.
  - `changed?` optional controller callback; Engine supplies it using Workspace's sanitized Candidate tree scan, so Harness never runs Git against the Candidate directly.

## Kogen.Shaper
- `shape(%Kogen.Shaper.Request{}) :: {:ok, %Kogen.Shaper.Result{}} | {:error, term()}`; the controller runs the Harness shaper, lints the generated Intent, runs the project's `acceptance_checks`, and applies red-on-base validation. A `test keep` item that fails on the base is reclassified as `test` and recorded as an approval warning. Candidate validation failures return to the same model conversation for at most four repair rounds, subject to the unchanged turn and wall limits.
- Each `%Kogen.Harness.ShapeCall{}` records the shape model, effort, per-call token counts, and wall time. The transcript is stored outside the project checkout.

## Kogen.Checks
- `fix(workdir, Project.t(), run_dir, env) :: {:ok, [ProcResult]}`: safe formatters only; `env` is the target project's explicit process environment.
- `run_all(workdir, Project.t(), run_dir, env, git_env, sandbox) :: {:ok, %{tree: sha, receipts: [Receipt.t()], status: :pass | {:fail, [String.t()]}}} | {:error, Failure.t()}`: checks run with `env` under the supplied sandbox; Git tree calls use `git_env`; the tree is hashed before and after, with a change reported as `:candidate`/`:tree_mutated`.
- `acceptance(workdir, Intent.t(), run_dir, env, git_env, sandbox) :: {:ok, %{status: :pass | {:fail, [id]}, ledger: [LedgerRow.t()]}} | {:error, Failure.t()}`: the formatter source is embedded at compile time and written into run_dir, never into the Candidate. Tests run with `env` under the supplied sandbox; Git tree calls use `git_env`.
- `red_on_base(base_workdir, Intent.t(), run_dir, env, git_env) :: :ok | {:error, Failure.t()}`
- `validate_shape(%Kogen.Checks.ShapeValidation{}) :: {:ok, [Kogen.Contracts.ShapeWarning.t()]} | {:error, Failure.t()}` stages the candidate test briefly, runs project acceptance checks, verifies that checks leave the tree unchanged, reclassifies red `test keep` items, validates red-on-base rules, and restores the checkout.
- `protected_violations(workdir, base_sha, manifest :: %{path => sha256}, git_env) :: {:ok, [path]}`
- `scope_violations(workdir, base_sha, Intent.t(), Project.t(), allowed_extra :: [path], git_env) :: {:ok, [path]}`

## Kogen.Engine
- `run(Kogen.Engine.Build.Request.t()) :: {:ok, Kogen.Engine.Build.Result.t()} | {:error, term()}` interprets Cycle effects and owns Build setup, stages, review, guard, commit, landing, and cleanup.
- `project_environment(workdir, Runtime.t())` runs `mise env -C <workdir> --json` using the supplied runtime.
- `candidate_environment(workdir, Runtime.t(), Project.t())` merges controller and mise values, then adds `.kogen/project.yaml` `env`; project values take precedence for setup, checks, acceptance, formatting, and Harness shell commands. If project `env` declares `PATH`, that value is used verbatim. Otherwise Kogen prepends the mise executable directory to the toolchain `PATH`; project configuration that needs extra bins must compose them explicitly. Build and shaping runs set `MISE_STATE_DIR` and `MISE_CACHE_DIR` under their own run directories before `mise env` and reapply them after project env merging. Tool installs remain in the inherited `MISE_DATA_DIR`. The Ledger acceptance runner prefixes its Elixir/Mix command with `mise exec --` when `MISE_CONFIG_FILE` is set.
- `Kogen.Engine.Runtime` is the runtime value and environment helpers (`git_environment/1`, `process_env/2`, `for_project/2`, `temporary_directory/1`, `output_tail/1`). `Kogen.Contracts.MiseEnvironment` owns pure mise environment updates (`trust_workspace/2`, `add_trusted_workspace/2`, `for_run/2`). Neither contains ambient discovery. The explicit `KOGEN_SANDBOXED` marker is retained as runtime metadata so a Build inside Kogen's own sandbox does not attempt to nest Seatbelt.
- `Kogen.Contracts.CommandExit.tool_missing?/1` classifies process statuses 126 and 127 as unavailable tools. Check, acceptance, formatter, fix, and setup command paths use this shared classification so missing commands cannot be sent as Candidate repair feedback.
- `%Kogen.Proc.Sandbox{}` is passed to Developer shell, done-gate checks, final checks, acceptance, and setup commands. On macOS it generates a Seatbelt profile that allows reads broadly and writes only to the Candidate workspace, run dir, TMPDIR, `~/.cache/mise`, `~/.hex`, `~/.cache/rebar3`, and `~/.npm`. Run-local mise state and cache stay under the writable run dir, so trusted-config and tracked-config symlinks do not require writes to `~/.local/state/mise`, and tool installations under `MISE_DATA_DIR` remain outside the write grant. The profile denies reads/writes to `~/.codex`, `~/.kogen/credentials*`, `~/.ssh`, `~/.gnupg`, and `~/Library/Keychains`, and denies writes to the origin and project checkout. `sandbox: false` in `.kogen/project.yaml` disables it for debugging. Linux currently runs without confinement; bubblewrap remains TODO. Network remains allowed.
- `Kogen.Engine.Environment` resolves an explicit workdir using the supplied runtime and `Kogen.Proc`.

## Kogen.Build.Cycle (pure)
- `new(%{approval: Approval, repairs: 2, recipe: Recipe.t()}) :: state`
- `step(state, event) :: {state, [effect]}`
- The recipe is plain data: its name, ordered stage list, model/effort tuple for each role, builder tool set (`full` or `shell`), and optional escalation policy. `staged` uses context `gpt-6-luna/low`, planner and reviewer `gpt-6.1-sol/high`, and the Build's `--model`/`--effort` for the builder. Its order is context, plan, develop, done gate, fix, checks, review, commit, land. `plan-shell` uses planner `gpt-6.1-sol/high` for one turn with no tools, with only the approved Intent text and `git ls-files` output (capped at 160,000 characters) in its prompt. The same Intent text starts the shell-only Builder request, followed by the benchmark-matched plan hand-off addendum. There is no context model call. Deterministic gate, fix, checks, commit, and land remain in the recipe. `direct` and `direct-shell` use only the Build model/effort for the developer; the former has the full builder tool set, the latter only the sandboxed shell tool. `direct-escalate` and `escalate-shell` use the direct path, with the latter using the shell-only tool set. Each can make one fresh-Candidate attempt using `gpt-6.1-sol/high` when the builder would stop on `repair_cap`, `unchanged`, or a red done gate. Escalation receives the Intent and a compact summary of the last gate findings.
- Events: `:start`, `{:stage_ok, stage, data}`, `{:stage_failed, stage, Failure.t()}`, `{:review, :accept | :revise, findings}`, `{:landed, sha}`, `{:base_moved}`.
- Effects:
  - `{:run, :context | :plan | :develop | :fix | :check | :review | :commit | :land, args}`
  - `{:record, map}`
  - `{:finish, :landed | :failed | :parked, reason}`

## Kogen.State
- `%Kogen.State.Approval{}`, as defined in T9's brief.
- `%Kogen.State.Event{}` is a decoded run-journal entry. `decode_event/1` owns its JSON string-key edge and returns typed fields for reports. Its top-level `status` is reserved for run lifecycle values; check and acceptance outcomes use `result`.
- Functions:
  - `approve(repo, Approval, git_env)`
  - `approval(repo, slug, git_env)`
  - `claim(repo, run_id, git_env) :: :ok | {:error, {:claimed, run_id}}`
  - `release(repo, run_id, git_env)`
  - `start_run(root, Approval) :: {:ok, %Kogen.State.Run{}}`
  - `record(Run, map) :: :ok`
  - `decode_event(binary) :: {:ok, Event.t()} | {:error, :invalid_event}`
  - `put_landing(Run, %{approval_commit, expected_parent, final_tree, candidate_commit}) :: :ok`
  - `load(root, run_id)`
  - `list(root)`
  - `status(repo, root, slug, branch, git_env) :: :draft | :approved | :building | :landed | :failed | :parked`
  - `reconcile(repo, root, Run, branch, git_env)`
- Run dir layout: `<state_root>/runs/<run_id>/run.json`, `events.jsonl`, `transcripts/`, `logs/`. Kernel sets `<state_root>` to `~/.kogen/workspaces/<project-key>`, alongside the Candidate checkouts. Run records move there because the sandbox must deny writes to the entire project checkout and origin. Status, report, and reconcile can read legacy runs under `<project>/.kogen/runs` during transition.

## Commit trailers (landing commit)
- `Kogen-Intent: <slug>`
- `Kogen-Run: <run_id>`
- `Kogen-Approval: <approval commit sha>`
- `Kogen-Receipt: <final tree sha>`

## Kogen.Kernel and CLI
- `Kogen.Kernel.intent_check(path) :: {:ok, Intent.t()} | {:error, term()}` parses and lints a local Intent.
- `approval_preview(slug, project_root, origin, base, by) :: {:ok, ApprovalPreview.t()} | {:error, term()}` reads the project Intent and acceptance file, captures the current base SHA, and prepares the protected-file manifest.
- `approve(ApprovalPreview.t()) :: {:ok, approval_commit_sha} | {:error, term()}` writes the immutable approval ref.
- `build(BuildOptions.t()) :: {:ok, Kogen.Engine.Build.Result.t()} | {:error, term()}` discovers runtime and provider configuration, resolves the selected Build recipe, then delegates execution to `Kogen.Engine`. At Build start, a moved base is accepted only if the approved base is an ancestor of the current tip and every path in the approval's protected manifest has unchanged contents between those commits; otherwise the Build is refused (a changed protected path is named in the reason). An accepted Build starts from the current tip. Candidate/environment/provider/controller failures map to CLI exit codes 1/3/4/70. Candidate repair resumes Developer with the failure output, up to two repairs.
- The existing six argument `build(slug, project_root, origin, base, model, effort)` entry point remains as a default-options wrapper.
- `build(Kogen.Engine.Build.Request.t())` remains available for explicit/test requests and delegates to `Kogen.Engine.run/1`. The request carries explicit `home` and `workspace_root` values; Engine does not discover HOME.
- `provider_login(label)`, `provider_logout(label)`, and `provider_list()` manage saved ChatGPT accounts. Login uses the open-source Sign in with ChatGPT PKCE flow at `auth.openai.com`, a loopback callback on `127.0.0.1:1455`, and a stable host ID. The CLI prints the authorization URL and `Continue with ChatGPT`; after first authorization it shows `You're using your ChatGPT plan` once.
- `kogen provider list`, `kogen provider login chatgpt [--as label]`, and `kogen provider logout chatgpt [--as label]` need no project checkout. Builds use the Kogen-owned credential by default; Codex credentials are read only when the owner passes `--borrow codex`. The Build receipt records credential source and account label.
- `status(project_root, origin | nil, base) :: {:ok, [IntentStatus.t()]} | {:error, term()}` reports one record for each `.kogen/intents/*/intent.md`; approval comes from the selected origin's `refs/kogen/intents/<slug>` ref, landing from its target branch's `Kogen-Intent` trailer, and in-flight state from run records.
- `report(slug, project_root, origin | nil, base) :: {:ok, json_binary} | {:error, term()}` returns the latest run's recipe, configured role models and efforts, escalation policy and outcomes, per-attempt model/token/wall summaries, approval/base/candidate/landed SHAs, acceptance ledger, check receipts, model stages, non-model phase timings and failures. Its lifecycle status and landed SHA use the same origin checks as `status`.
- Each Build `model_stage` report row includes the attempt, model, effort, token counts, and `wall_ms` spent in that stage.
- `reconcile(run_id, project_root, origin, base) :: {:ok, :landed | :unchanged} | {:error, term()}` closes a run journal after a crash following successful CAS.
- Project commands require `--project <checkout>` and accept `--origin <repo>` and `--base <branch>` (default `main`). If `--origin` is omitted, Kogen uses the checkout's `remote.origin.url` when it names an existing local Git repository, otherwise the project checkout. Status and report inspect that origin directly; they do not depend on local remote-tracking refs or a fetch. Build additionally accepts `--recipe staged|plan-shell|direct|direct-shell|direct-escalate|escalate-shell` (default `staged`), `--model` and `--effort` for the builder only, `--as`, and explicit `--borrow codex`; approval requires `--by` and supports `--yes` to skip its TTY prompt.
- `bin/kogen-bench <task_dir> <work_dir> <out_dir>` accepts `KOGEN_BENCH_RECIPE=staged|plan-shell|direct|direct-shell|direct-escalate|escalate-shell` (default `staged`), `KOGEN_BENCH_MODEL`/`KOGEN_BENCH_EFFORT` for the builder (defaults `gpt-6-luna`/`max`), and `KOGEN_BENCH_SHAPE_MODEL`/`KOGEN_BENCH_SHAPE_EFFORT` for shaping (defaults `gpt-6-luna`/`max`). `usage.json` records selected builder and shape settings, shape command wall time, per-call model, token and wall usage, and setup, check, gate, fix, commit, land and report timings in `events.jsonl`. The total reconciles end-to-end wall time against summed model-call wall time, the union of timed phase intervals (so nested gate/check timings count once), and an unaccounted remainder. Staged and plan-shell planners use Sol high; staged reviewer defaults remain Sol high. String setup commands run through `sh -c` in the project workdir with the task environment applied. The generated task `PATH` is composed explicitly as mise's bin directory, `BENCH_EXTRA_PATH`, then the task's configured `PATH`.
- Runtime discovery, including HOME, environment, cwd, `mise`, credential paths and escript/ERTS markers, lives in `Kogen.Kernel.RuntimeDiscovery`. The runtime value and explicit `mise env -C <workdir> --json` call live in `Kogen.Engine`. Harness and checks receive the target process environment; Workspace receives its Git-allowlisted projection.

### Shaping an Intent from a task statement

Run `kogen intent shape <slug> --task-file <path> --project <checkout>` to create `.kogen/intents/<slug>/intent.md` and `.kogen/acceptance/<slug>_test.exs`. The command validates both files and never approves the Intent. `--model` and `--effort` default to Build's `gpt-6-luna` and `max`; `--json` emits per-call usage for automation.

### Writing an acceptance test for a Build-engine Intent

Use `Kogen.E2e.Build.prepare_seed!/1` once in `setup_all/1`, then pass its compiled tiny Mix project to `run!/3`. The helper creates a bare origin and checkout, writes and approves the Intent through Kernel approval code, uses a fake `mise`, and returns the `Kogen.Engine.Build.Result` with decoded run events and fixture paths. Script provider responses by stage; the response queue must cover each provider request.

```elixir
seed = Kogen.E2e.Build.prepare_seed!(shared_dir)

script = [
  Kogen.E2e.ScriptedProvider.answer(:context, "TinyApp.value/0 is relevant."),
  Kogen.E2e.ScriptedProvider.answer(:plan, "Set the ready value."),
  Kogen.E2e.ScriptedProvider.write(
    :develop,
    "lib/tiny_app.ex",
    "defmodule TinyApp do\n  def value, do: :ready\nend\n"
  ),
  Kogen.E2e.ScriptedProvider.answer(:develop, "Done."),
  Kogen.E2e.ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
]

%Kogen.E2e.Build.Result{build: build, events: events, fixture: fixture} =
  Kogen.E2e.Build.run!(tmp_dir, script, %Kogen.E2e.Build.Options{seed_project: seed})
```

`fixture` exposes `project_root`, `origin`, `approved_base`, `approval_commit`, and `git_env` for Git and lifecycle assertions. The result also has the persisted `run_status` and whether the Build claim could be reacquired. Use `Kogen.E2e.ScriptedProvider.edit/4` to make repair turns; a response step tagged `:review` can revise once and a later `:review` step can accept.
