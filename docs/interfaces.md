# Kogen P0 interfaces (authoritative)

This file is the contract between domains. Change it only through the integrator. Types refer to `Kogen.Contracts.*` structs unless stated. Paths are absolute strings. Only `Kogen.Kernel` reads HOME, env or cwd; everyone else receives explicit values.

## Dependency graph (Boundary, acyclic)
`contracts` ← every domain. `workspace` → proc. `provider` → proc. `state` → workspace. `checks` → proc, workspace, project. `harness` → proc, provider, project. `build` is pure (contracts, plus resilience's error classes). `shaper` → checks, harness, intent, proc, project. `engine` → build, intent, proc, project, provider, workspace, state, checks, harness. `runner` → build, checks, engine, harness, state. `queue` → proc, state, workspace. `kernel` → proc, project, intent, provider, engine, runner, workspace, state, checks, harness, shaper, queue, cli. `cli` is pure (no deps).

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
- `park(path, origin, run_id, git_env) :: :ok`: pushes HEAD to `refs/kogen/parked/<run_id>`. Ladder rungs park each red Candidate as `<run_id>-<attempt>`.
- `restore_protected(%{workdir, origin, base_sha, slug, intent_bytes, acceptance_files, manifest, git_env}) :: {:ok, [path]} | {:error, term()}` restores protected Candidate paths to their approved bytes and removes the acceptance source copy.
- `publish_branch(repo, branch, sha, git_env) :: :ok | {:error, term()}` creates or moves `refs/heads/<branch>`.
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
- Project settings may include `base: <branch>` and `build: {recipe, roles, wall_minutes}`. An explicit project Build recipe overrides the matching machine setting; `~/.kogen/config.yaml` supplies the recipe when the project omits one, and `ladder` is used when both omit it. `wall_minutes` (a positive integer, project over machine) sets a ladder's whole-Build wall budget, default 60. The account is a machine choice (`kogen provider use`), never committed; a legacy `account: <label>` still loads for one CLI generation and warns. Build roles (`builder`, `planner`, `reviewer`, `context`, `auditor`, `shaper`) accept `model` and `effort`; project values override matching values from `~/.kogen/config.yaml`.
- Intent files live at `.kogen/intents/<slug>/intent.md`; `parse/1` derives `<slug>` from the parent directory.
- Shaped Intents end with `## Request`, copied verbatim from the source task file or stdin. `kogen intent shape <slug> <file>` reads stdin when the file is `-`; shaping waits for the model and validation without a wall timeout and retains the 60-turn limit. The Request body is context only; Acceptance remains the completion gate. Parsing preserves Request bytes through end-of-file, and Intent lint word, prose, and size limits do not inspect it. Older human-authored Intents may omit Request.
- The full Intent file participates in the approval hash, including Request. Planner and builder messages include the approved Intent text verbatim alongside Brief, Acceptance, and Notes.
- Acceptance test source files live at `.kogen/acceptance/<slug>_test.exs` for approval and shaping, and are installed into the Candidate at `test/acceptance/<slug>_test.exs`. The source copy is removed from the Candidate before its commit so the landed tree contains only the test copy.
- `.kogen/project.yaml` may declare `format: [argv...]` beside `checks:` and `setup:`. Shaping appends the generated source paths to this argv. If omitted, it derives the formatter from the first `checks:` argv containing both `format` and `--check-formatted`, removing the latter flag; otherwise it uses `mix format`. If the formatter is missing (`:enoent` or exit 127), shaping records a warning and continues to the acceptance checks; those checks still run normally.
- `.kogen/project.yaml` may declare `setup_outputs: [relative, paths]` to reuse successful setup output across shaping, approval, and Build. The cache key includes the base Git tree, setup specs and project env, plus the resolved toolchain identity. Omitted or empty outputs preserve setup execution without caching.

## Kogen.Provider
- `Kogen.Provider.ChatGPT.config(auth_path) :: {:ok, %Kogen.Provider.ChatGPT.Config{}} | {:error, ProviderError.t()}`
- `owned_config(root, :file | :keychain, label)` uses Kogen's saved ChatGPT plan credential. Builds and shaping select the account from project `account`, defaulting to `default`.
- Kogen-owned requests use `https://api.openai.com/v1/responses`; refresh tokens are rotated under a cross-process lock. Linux stores credentials in a 0600 file. macOS encrypts credentials with AES-256-GCM into `~/.kogen/credentials/chatgpt-<label>.enc` and stores the base64 32-byte key under Keychain service `kogen`, account `chatgpt:<label>:key`; old base64 credentials under `chatgpt:<label>` remain readable and migrate on save.
- `KOGEN_AUTH_PATH` is a benchmark/CI escape hatch for an injected temporary auth file. It is not a user-facing CLI option; normal use signs in through `kogen provider login chatgpt`.
- `respond(config, ModelRequest.t()) :: {:ok, ModelResponse.t()} | {:error, ProviderError.t()}` (the ProviderPort behaviour is `respond(term(), ModelRequest.t())`)
- `ChatGPT.Config` caps every streamed request: `first_byte_timeout_ms` (default 120_000) aborts a request whose body has not started, `timeout_ms` (300_000) is the idle limit between chunks, and `total_timeout_ms` (600_000) is a hard limit that trickling chunks cannot extend. Each is a `:timeout` error.
- `Kogen.Provider.Fake.config(fixture_paths)` with the same `respond/2`.
- `ModelResponse.raw_items` = the full ordered output items. The harness sends them back with `function_call_output` items `{type: "function_call_output", call_id, output}`.

## Kogen.Harness
- `context_pack(%Kogen.Harness.Opts{}, intent_text) :: {:ok, %Kogen.Harness.Pack{text, refs, usage}} | {:error, term()}`
- `shape(%Opts{}, slug, task, history, failure_text, turn_offset) :: {:ok, %ShapePass{items, text, calls, turns}} | {:error, term()}`; the stage exposes read/search and writes only the two slug-specific generated files.
- `plan(%Opts{}, pack, intent_text) :: {:ok, %Kogen.Harness.Plan{text, usage}} | {:error, term()}`; with `planner_difficulty: true` the ls-files planner also writes one `Difficulty: easy|normal|hard` line.
- `develop(%Opts{}, intent_text, plan | nil, resume :: nil | %{previous_items: list(), failure_text: String.t()}) :: {:ok, %Kogen.Harness.Result{outcome: :done | :gate_red | :gate_environment | :turn_cap | :wall_cap, gate: map() | nil, items: list(), turns, usage, transcript_path}} | {:error, term()}`
- `review(%Opts{}, intent_text, diff, check_summary) :: {:ok, %Kogen.Harness.Review{verdict: :accept | :revise, findings: [String.t()], usage}} | {:error, term()}`
- `ask(%Opts{}, %{stage, role, instructions, text}) :: {:ok, %{text, usage}} | {:error, term()}`: one no-tool request on the role's model through the resilient Exchange. The Runner's test auditor uses it with role `auditor`.
- `%Kogen.Harness.Opts{}` fields:
  - `workdir`, `run_dir`, `project`, `sandbox`
  - `provider_mod`, `provider_config`
  - `proc_mod`
  - `models` (`%{builder: {"gpt-6-luna", "max"}, strong: {"gpt-6.1-sol", "high"}}`, plus optional `context`, `planner`, `reviewer` and `auditor`)
  - `limits` (`%{max_turns: 60, wall_ms: 1_800_000}` for Build stages; shaping uses `%{max_turns: 60, wall_ms: :infinity}`)
  - `resilience` (`%Kogen.Resilience.Policy{}`): every model request of every stage (shaping, context, plan, develop, review) goes through `Kogen.Harness.Exchange`, which makes up to `max_attempts` (4) attempts, each capped at `request_cap_ms` (600_000) and by the remaining wall budget. `:timeout`, `:transport`, `:overload` and `:malformed` errors are retried after an exponential backoff with jitter (`backoff_base_ms` 2_000 doubling to `backoff_max_ms` 60_000), only while the remaining wall budget exceeds the delay. `:login` and `:usage_limit` are never retried. After `overload_fallback_after` (2) consecutive overloads the request moves to the next entry of `fallbacks[role]` (builder, planner, reviewer and context default to `{"gpt-6.1-sol", "medium"}`; reasoning items are dropped because they belong to the previous model) and a `model_fallback` event is recorded beside each `provider_retry` event. The Build cycle additionally repeats a stage once or twice after `:transport`, `:overload` or `:malformed`, never after `:timeout`, `:login` or `:usage_limit`.
  - Request journal: `Kogen.Harness.Exchange` appends one record per provider call to `requests.jsonl` in the run directory (`Kogen.Resilience.RequestLog`), whatever the outcome; a retried request leaves one record per attempt. Fields: `stage`, `turn`, `attempt` and `rung` (from `Opts.request_tags`, set by the Build; null elsewhere), `model`, `effort`, `started_at`, `first_byte_at` (null when no byte arrived or the provider cannot tell), `ended_at` (epoch ms), `outcome` (`ok`, `timeout`, `transport`, `overload`, `malformed`, `usage_limit`, `login`), `retries` (earlier attempts), `tokens` (`input`, `cached_input`, `output`, `reasoning`, `cache_write`; null unless the response reported usage), `history_items`, `history_bytes` and `tool_output_bytes` (tool outputs in the history sent). The provider reports the first byte through `ModelRequest.on_first_byte`.
  - `before_gate` optional zero-arity callback; Kernel uses it to check the approval protected manifest and scope before the done gate runs a fixer or check.
  - `changed?` optional controller callback; Engine supplies it using Workspace's sanitized Candidate tree scan, so Harness never runs Git against the Candidate directly.

## Kogen.Shaper
- `shape(%Kogen.Shaper.Request{}) :: {:ok, %Kogen.Shaper.Result{}} | {:error, term()}`; the controller runs the Harness shaper, lints the generated Intent, runs the project's `acceptance_checks`, and applies red-on-base validation. A `test keep` item that fails on the base is reclassified as `test` and recorded as an approval warning. Candidate validation failures return to the same model conversation for at most four repair rounds, subject to the unchanged turn limit; there is no default shaping wall timeout.
- Each `%Kogen.Harness.ShapeCall{}` records the shape model, effort, per-call token counts, and wall time. The transcript is stored outside the project checkout.

## Kogen.Checks
- `fix(workdir, Project.t(), run_dir, env) :: {:ok, [ProcResult]}`: safe formatters only; `env` is the target project's explicit process environment.
- `run_all(workdir, Project.t(), run_dir, env, git_env, options)` runs checks with `env` under the supplied sandbox; Git tree calls use `git_env`; the tree is hashed before and after, with a change reported as `:candidate`/`:tree_mutated`. `options` may be a sandbox or a map containing `sandbox`, `check_baseline`, and the approval-only `baseline_run?` flag.
- Approval runs each configured check once after setup and stores a green/red baseline in the approval record. Red checks print up to five findings plus a hint. During Build, a check is reported as a base-red warning when its current findings are a subset of the approval findings with matching file and rule/test identity, or when it already failed on the base without parseable findings (unparseable or unavailable there); otherwise new findings still fail. Acceptance checks never use this baseline.
- `acceptance(workdir, Intent.t(), run_dir, env, git_env, sandbox) :: {:ok, %{status: :pass | {:fail, [id]}, ledger: [LedgerRow.t()]}} | {:error, Failure.t()}`: the formatter source is embedded at compile time and written into run_dir, never into the Candidate. Tests run with `env` under the supplied sandbox; Git tree calls use `git_env`.
- `red_on_base(base_workdir, Intent.t(), run_dir, env, git_env) :: :ok | {:error, Failure.t()}`
- `validate_shape(%Kogen.Checks.ShapeValidation{}) :: {:ok, [Kogen.Contracts.ShapeWarning.t()]} | {:error, Failure.t()}` stages the candidate test briefly, runs project acceptance checks, verifies that checks leave the tree unchanged, reclassifies red `test keep` items, validates red-on-base rules, and restores the checkout.
- `protected_violations(workdir, base_sha, manifest :: %{path => sha256}, git_env) :: {:ok, [path]}`
- `scope_violations(workdir, base_sha, Intent.t(), Project.t(), allowed_extra :: [path], git_env) :: {:ok, [path]}`

## Kogen.Engine
- `start(Kogen.Engine.Build.Request.t()) :: {:started, Session.t(), [effect]} | {:ok, Result.t()} | {:error, term()}` checks the approval and base, opens the run journal, takes the claim and prepares the first Candidate; a Build that cannot start is already finished. Engine owns single-Candidate work: setup, stages (`Build.StageRunner`), review, guard, the check stage, commit, landing, Candidate snapshots and cleanup (`Build.Finish`).
- `project_environment(workdir, Runtime.t())` runs `mise env -C <workdir> --json` using the supplied runtime.
- `candidate_environment(workdir, Runtime.t(), Project.t())` merges controller and mise values, then adds `.kogen/project.yaml` `env`; project values take precedence for setup, checks, acceptance, formatting, and Harness shell commands. If project `env` declares `PATH`, that value is used verbatim. Otherwise Kogen prepends the mise executable directory to the toolchain `PATH`; project configuration that needs extra bins must compose them explicitly. Build and shaping runs set `MISE_STATE_DIR` and `MISE_CACHE_DIR` under their own run directories before `mise env` and reapply them after project env merging. Tool installs remain in the inherited `MISE_DATA_DIR`. The Ledger acceptance runner prefixes its Elixir/Mix command with `mise exec --` when `MISE_CONFIG_FILE` is set.
- `Kogen.Engine.Runtime` is the runtime value and environment helpers (`git_environment/1`, `process_env/2`, `for_project/2`, `temporary_directory/1`, `output_tail/1`). `Kogen.Contracts.MiseEnvironment` owns pure mise environment updates (`trust_workspace/2`, `add_trusted_workspace/2`, `for_run/2`). Neither contains ambient discovery. The explicit `KOGEN_SANDBOXED` marker is retained as runtime metadata so a Build inside Kogen's own sandbox does not attempt to nest Seatbelt.
- `Kogen.Contracts.CommandExit.tool_missing?/1` classifies process statuses 126 and 127 as unavailable tools. Check, acceptance, formatter, fix, and setup command paths use this shared classification so missing commands cannot be sent as Candidate repair feedback.
- `%Kogen.Proc.Sandbox{}` is passed to Developer shell, done-gate checks, final checks, acceptance, and setup commands. On macOS it generates a Seatbelt profile that allows reads broadly and writes only to the Candidate workspace, run dir, TMPDIR, `~/.cache/mise`, `~/.hex`, `~/.cache/rebar3`, and `~/.npm`. Run-local mise state and cache stay under the writable run dir, so trusted-config and tracked-config symlinks do not require writes to `~/.local/state/mise`, and tool installations under `MISE_DATA_DIR` remain outside the write grant. The profile denies reads/writes to `~/.codex`, `~/.kogen/credentials*`, `~/.ssh`, `~/.gnupg`, and `~/Library/Keychains`, and denies writes to the origin and project checkout. `sandbox: false` in `.kogen/project.yaml` disables it for debugging. Linux currently runs without confinement; bubblewrap remains TODO. Network remains allowed.
- `Kogen.Engine.Environment` resolves an explicit workdir using the supplied runtime and `Kogen.Proc`.

## Kogen.Runner
- `run(Kogen.Engine.Build.Request.t()) :: {:ok, Kogen.Engine.Build.Result.t()} | {:error, term()}` starts the Build through Engine and interprets Cycle effects to the end. It owns the multi-Candidate policy: `{:escalate, data}` moves to the next ladder rung on a fresh Candidate (checked against the wall budget; the previous Candidate is recorded and parked), `{:parallel, %{members}}` runs members concurrently on separate Candidates with sub-cycles, `{:adopt, attempt}` continues from the chosen member, and `{:run, :audit, _}` runs the test auditor.
- The audit stage (`Kogen.Runner.Auditor` holds its prompt and verdict parsing) runs the acceptance ledger, asks the auditor once about failing items not judged yet in this Build, records `acceptance_upheld` or `acceptance_demoted` (with the auditor's reason) per item, excludes demoted items from `mix test` checks with `--exclude intent:<slug>/<id>`, and no longer counts their ledger failures. Upheld items are named in the next repair's feedback.
- Each rung records `rung_finished` with its attempt, builder model and effort, result, reason, wall time and summed model tokens.

## Kogen.Build.Cycle (pure)
- `new(%{approval: Approval, repairs: 2, recipe: Recipe.t()}) :: state`
- `step(state, event) :: {state, [effect]}`
- The recipe is plain data: its name, ordered stage list, model/effort tuple for each role, builder tool set (`full` or `shell`), and optional escalation policy. Model, effort, and recipe are configured in `.kogen/project.yaml` under `build`; matching values in `~/.kogen/config.yaml` provide machine defaults. `staged` uses context `gpt-6-luna/low`, planner and reviewer `gpt-6.1-sol/high`, and the configured builder role. Its order is context, plan, develop, done gate, fix, checks, review, commit, land. `plan-shell` uses planner `gpt-6.1-sol/high` for one turn with no tools, with only the approved Intent text and `git ls-files` output (capped at 160,000 characters) in its prompt. The same Intent text starts the shell-only Builder request, followed by the benchmark-matched plan hand-off addendum. There is no context model call. Deterministic gate, fix, checks, commit, and land remain in the recipe. `direct` and `direct-shell` use the configured builder model/effort for the developer; the former has the full builder tool set, the latter only the sandboxed shell tool. `direct-escalate` and `escalate-shell` use the direct path, with the latter using the shell-only tool set. Each can make one fresh-Candidate attempt using `gpt-6.1-sol/high` when the builder would stop on `repair_cap`, `unchanged`, a red done gate, `turn_cap`, or `wall_cap`. Escalation receives the Intent and a compact summary of the last gate findings.
- `ladder` (the default), `ladder-luna` and `ladder-sol-medium` are plan-shell recipes with ladder data: rungs, `parallel_on_hard: 2`, `repair_cap: 6`, `wall_ms: 3_600_000` `repeat_from: 2`, `on_hard: :parallel`, `pause_ms: 300_000` and `pause_cap_ms: 86_400_000`: after the last rung, fresh attempts cycle through the rungs from index 2 (`sol-high-2`, `raw-request-2`, ...) until the wall budget is spent, so a started Build only ends green, out of budget, or on a terminal failure. `ladder` uses planner and auditor `gpt-6.1-sol/high` and rungs `builder` (the configured builder role, plan), `sol-medium` (`gpt-6.1-sol/medium`, plan), `sol-high` (`gpt-6.1-sol/high`, plan) and `raw-request` (`gpt-6.1-sol/high`). `ladder-luna` uses `gpt-6-luna/max` and `ladder-sol-medium` uses `gpt-6.1-sol/medium` for the planner, the auditor and all four rungs (`builder`, `fresh-2`, `fresh-3`, `raw-request`). A `raw-request` rung's builder gets the verbatim `## Request` and the acceptance test source, with no plan.
- Ladder behaviour: every rung starts on a fresh Candidate from the base and sees summaries of earlier rungs' last gate findings, never their diffs. A rung repairs while each red gate has strictly fewer failures (failing tests or findings, plus red commands without findings) than the last, at most `repair_cap` times; without a count it gets two repairs. `unchanged`, `no_progress`, the repair cap, turn or wall caps, provider stops, an unusable check run after repairs, and environment or controller failures in plan, develop, fix, check or audit end only the rung; landing and journal failures stay terminal. A usage limit or lost login (`Kogen.Resilience.Policy.waitable?/1`, the classes the Exchange never retries) pauses the Build (a `paused` event, `pause_ms` at a time, outside the wall budget, at most `pause_cap_ms`) and then reruns the stage. With `on_hard: :skip_first` a hard plan starts at the second rung instead of running two in parallel. `raw-request` rungs are marked `experimental` in `rung_finished` and the report. When the plan's difficulty line says hard, the first two rungs run in parallel and the Build continues from the better one. A red gate whose only failures are acceptance tests (and a check stage red only on acceptance items) goes to the audit stage first; if every failing item is demoted the Candidate counts as green, but only when it passes at least one non-demoted change item (an Acceptance item verified by `test`); otherwise it is repaired. The auditor only corrects a test toward the approved verbatim Request; it never changes scope. Acceptance tests that are not red on the base are recorded as an `acceptance_warning` instead of stopping.
- `Kogen.Build.Selector` ranks Candidates: green on every check other than acceptance items first, then fewer failing acceptance items, fewer failing tests, and a smaller diff (protected and Intent files excluded). A failed ladder Build pushes the best recorded Candidate to `kogen/<slug>` in the origin and records `best_candidate` with its metrics and failing items.
- Events: `:start`, `{:stage_ok, stage, data}`, `{:stage_failed, stage, Failure.t()}`, `{:review, :accept | :revise, findings}`, `{:landed, sha}`, `{:base_moved}`, `:budget_exhausted`, `{:parallel_done, outcomes}`.
- Effects:
  - `{:run, :context | :plan | :develop | :fix | :check | :review | :audit | :commit | :land, args}`
  - `{:escalate, data}`, `{:parallel, %{members}}`, `{:adopt, attempt}`
  - `{:record, map}`
  - `{:finish, :landed | :failed | :parked, reason}`; a parallel member's sub-cycle finishes `:green` or `:failed`

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
  - `attempt_usage(Run, attempt) :: {:ok, %{tokens, model_wall_ms}} | {:error, term()}` sums an attempt's `model_stage` events plus the `requests.jsonl` usage of its stages that failed or were cut off (`unfinished_usage(Run, events)` returns that usage as `partial: true` `model_stage` events, which `Report` adds to `model_stages`)
  - `load(root, run_id)`
  - `list(root)`
  - `status(repo, root, slug, branch, git_env) :: :draft | :approved | :building | :landed | :failed | :parked`
  - `reconcile(repo, root, Run, branch, git_env)`
- Run dir layout: `<state_root>/runs/<run_id>/run.json`, `events.jsonl`, `transcripts/`, `logs/`. Kernel sets `<state_root>` to `~/.kogen/workspaces/<project-key>`, alongside the Candidate checkouts. Run records move there because the sandbox must deny writes to the entire project checkout and origin. Status, Build reports and crash recovery also read legacy runs under `<project>/.kogen/runs` during transition. The queue's lock (`queue.pid`), stop request (`queue.stop`) and background log (`queue.log`) live in `<state_root>` too.

## Commit trailers (landing commit)
- `Kogen-Intent: <slug>`
- `Kogen-Run: <run_id>`
- `Kogen-Approval: <approval commit sha>`
- `Kogen-Receipt: <final tree sha>`

## Kogen.Queue
- `Status.list(project_root, state_root, origin, base, git_env) :: {:ok, [IntentStatus.t()]}` derives one record per `.kogen/intents/*/intent.md`: approval from the origin's `refs/kogen/intents/<slug>` ref (with its commit time), landing from the target branch's `Kogen-Intent` trailer (with its order), and in-flight state from run journals. `detail` is a failed or parked Build's reason, or a running Build's stage; `started_at` is when a running Build began.
- `Status.queued(statuses)` is the queue: approved Intents that are not landed, building, failed or parked, oldest approval first. The queue is never stored.
- `Recovery.recover(project_root, state_root, origin, base, git_env)` closes every running Build whose owner OS process is dead: landed if its candidate commit is on the branch, otherwise failed with reason `crashed` (`interrupted` when its last event is a SIGTERM `interrupted`); it releases the claim and deletes the checkout. Such a Build shows as `interrupted` in status and its report. `Recovery.run/6` does this for one Build.
- `Drain.run(state_root, hooks)` drains serially under `Lock`, one drain per project; a lock whose process is dead is taken over. Hooks: `recover`, `statuses`, `build(slug) :: {:ok, outcome}`, `say(line)`. A candidate failure continues the drain; environment, provider and Kogen failures stop it. Each approval is built at most once per drain.
- `Report.read/5` is the latest Build as JSON (`build_id`, `journal`, status, recipe, roles, attempts, approval, base/candidate/landed SHAs, acceptance ledger, check receipts, candidate diffs with commit and selector metrics, model stages, phase timings, failures, last gate, stop, and for ladders `rungs`, `parallel`, `acceptance_demoted` and `best_candidate`). A failed Build with a best candidate reads `needs attention: kogen/<slug>` as its status detail. `BuildSummary.latest/2` is the same Build in a few typed fields for text.

## Kogen.Kernel and CLI
- `approval_preview(slug, project_root, origin, base, by | nil) :: {:ok, ApprovalPreview.t()} | {:error, term()}` reads the project Intent and acceptance file, captures the current base SHA, runs setup and the configured checks, records their baseline in the approval, and prepares the protected-file manifest. Red configured checks warn but do not prevent approval; acceptance checks remain strict. When `by` is nil, the recorded approver is Git's resolved author identity (`user.name` and `user.email`); `--by` names the caller instead.
- `approve(ApprovalPreview.t()) :: {:ok, approval_commit_sha} | {:error, term()}` writes the immutable approval ref, which queues the Intent. It never starts the queue.
- `remove_intent(slug, project_root, origin, base, force) :: {:ok, commit_sha} | {:error, term()}` removes the Intent directory and source acceptance file in one path-limited commit, then removes its approval ref. An approved (queued), failed or parked Intent requires `--force`; an Intent in a running Build cannot be removed.
- `build(BuildOptions.t()) :: {:ok, Kogen.Engine.Build.Result.t()} | {:error, term()}` runs one Build; only the queue calls it. It discovers runtime and provider configuration, resolves the selected Build recipe, then delegates to `Kogen.Engine`. A moved base is accepted only if the approved base is an ancestor of the current tip and every path in the approval's protected manifest is unchanged between those commits. Candidate repair resumes Developer with the failure output, up to two repairs (ladder recipes repair on progress). `Kogen.Runner` runs the Build. `build(Kogen.Engine.Build.Request.t())` stays for explicit/test requests.
- `status/3`, `overview/3` (statuses plus the queue's `{:running, pid} | :stopped`), `report/4`, `build_summary/4`, `queue_start/4`, `queue_detach/3` and `queue_stop/3` resolve the project once (`Kernel.Queueing`) and run crash recovery before reading or draining.
- Accounts: logins are per machine. `provider_login(label)`, `provider_logout(label)`, `provider_list()` and `provider_use(label, project_root | nil)` manage saved ChatGPT accounts. Login uses the open-source Sign in with ChatGPT PKCE flow at `auth.openai.com`, a loopback callback on `127.0.0.1:1455`, and a stable host ID. `~/.kogen/accounts.yaml` (written only by `kogen provider use`) holds the default account and each project's own choice, keyed by the canonical project path; a Build or shaping run uses the project's choice, else the default, else the label `default`. A committed `account:` in `.kogen/project.yaml` is deprecated: it is still honoured for one CLI generation, after the project's machine choice, with a `kogen: moved:` warning on stderr.
- Runtime discovery, including HOME, environment, cwd, `mise`, credential paths and escript/ERTS markers, lives in `Kogen.Kernel.RuntimeDiscovery`. The runtime value and explicit `mise env -C <workdir> --json` call live in `Kogen.Engine`. Harness and checks receive the target process environment; Workspace receives its Git-allowlisted projection.

### Command line
The definitive tree (careful-rebuild/features/24-cli.md, 5 Oct 2026). Parsing and help text live in `Kogen.Cli` (pure); `Kogen.Kernel.CLI` runs commands.

```
kogen status [<slug>] [--watch] [--json]
kogen intent shape <slug> <file|-> [--json]
kogen intent approve <slug> [<hash>] [--by <name>]
kogen intent remove <slug> [--force]
kogen queue start [--detach]
kogen queue stop
kogen provider list
kogen provider login chatgpt [--as <label>]
kogen provider logout chatgpt [--as <label>]
kogen provider use chatgpt [--as <label>] [--project <checkout>]
kogen version
kogen help [<command> [<subcommand>]]
```
- Project commands take `--project <checkout>` (default: cwd), `--origin <repo>` and `--base <branch>`. Base selection is project `base`, then the origin HEAD branch recorded locally, then the checkout's current branch. Without `--origin`, Kogen uses the checkout's `remote.origin.url` when it names an existing local Git repository, otherwise the checkout itself. Status batches approval refs and landed trailers and never fetches.
- `kogen` and `kogen help` list commands only; `kogen <command>` lists its subcommands; `--help` works at every level. Unknown commands, unknown options and missing arguments print one targeted line plus only that command's help, exit 2.
- `status` prints the queue line, then Building (stage, elapsed, Build id), Queued (in order), Failed (reason, or `needs attention: kogen/<slug>` when a best candidate was pushed), Parked and Interrupted (reason, Build id), Drafts and the five most recent Landed. `status <slug>` prints that Intent and its latest Build (outcome, model time per stage, candidate diff, journal). `--json` prints JSON Lines, one `{slug, status, build_id, landed_sha}` object per Intent, or with a slug the Build report as one line (`{slug, status, build_id, landed_sha}` when there is no Build). `--watch` re-prints on change and returns when no Build runs and the queue is stopped; with a slug it exits 0 if the Intent landed, else 1.
- `intent approve <slug>` without a hash prints the review card and `kogen intent approve <slug> <hash8>`, exit 5 (advisory: needs a decision). With a hash of 6 to 64 hex characters that prefixes the Intent's SHA-256 it approves; a mismatch exits 1. There is no TTY prompt.
- `queue start` builds in the foreground and prints `building <slug>` and `landed <slug> <sha8> (Build <id8>)` or `failed <slug>: <class>/<reason> (Build <id8>)` per Build. Exit 0 all landed, 1 a Build failed, 3/4/70 stopped on an environment/provider/Kogen failure. A second start prints `queue: already running (pid N)` and exits 0. `--detach` starts the same drain in a new session (`queue.log` in the state root); it needs an installed kogen. `queue stop` asks the drain to stop after its current Build.
- `version` prints the source commit and its date, `kogen 6e826320 (2026-10-05)`, plus `uncommitted changes` for a dirty build; mix.exs stores it as `0.0.0+<sha8>.<yyyymmdd>[.dirty]` (Kogen has no product version yet).
- Exit codes: 0 done, 1 the answer is no, 2 usage, 3 environment, 4 provider, 5 needs a decision (advisory), 70 Kogen bug, 143 SIGTERM (the running Build is marked interrupted).
- Old forms exit 2 with `kogen: moved: use …` for this generation only (`Kogen.Cli.Moved`): `build`, `build show`, `report`, `approve`, `reconcile`, `intent check`, `intent close`, `--version`, `--task-file`, `--yes`, `--model`, `--effort`, `--recipe`, `--borrow`, and `--as` outside `provider`.
- `bin/kogen-bench <task_dir> <work_dir> <out_dir>` drives exactly these commands: `intent shape <slug> <prompt> --json`, `intent approve <slug> <sha256-prefix-of-the-shaped-intent> --by kogen-bench`, `queue start` (foreground; its exit code is the Build result) and `status <slug> --json` for `report.json`. With `KOGEN_BENCH_ACCOUNT` it binds the throwaway project with `kogen provider use chatgpt --as <label> --project <dir>`. It accepts `KOGEN_BENCH_RECIPE=ladder|ladder-luna|ladder-sol-medium|staged|plan-shell|direct|direct-shell|direct-escalate|escalate-shell` (default `ladder`), `KOGEN_BENCH_FORMAT_SCOPE=changed|all` (default `changed`), `KOGEN_BENCH_MODEL`/`KOGEN_BENCH_EFFORT` for the builder (defaults `gpt-6-luna`/`max`) and `KOGEN_BENCH_SHAPE_MODEL`/`KOGEN_BENCH_SHAPE_EFFORT` for shaping, and `KOGEN_BENCH_SHAPE_FALLBACK=raw|none` (default `raw`): when `intent shape` exits 4 (a provider error that survived its retries), `raw` builds from a minimal Intent whose `## Request` is the raw prompt and whose one `test keep` acceptance test is a smoke check that the Mix project loads, recording `"intent_source": "raw-fallback"`; `none` stops with the shaping exit status. It writes the recipe, model and format settings into the generated project's `.kogen/project.yaml`. `requests.jsonl` in the output directory is the shape and Build request journals, written for every run including failed and stopped ones. `usage.json` records selected builder and shape settings, shape command wall time, per-call model, token and wall usage, and setup, check, gate, fix, commit, land and report timings in `events.jsonl`; the total reconciles end-to-end wall time against summed model-call time, the union of timed phases and an unaccounted remainder. String setup commands run through `sh -c` in the project workdir with the task environment applied; the task `PATH` is mise's bin directory, `BENCH_EXTRA_PATH`, then the task's configured `PATH`. When the Build does not land but its report names a `best_candidate` branch, the runner writes that branch's diff against the base as `final.diff`, applies it to the work dir, exits 0, and records `"landed": false, "best_candidate": true` in `usage.json` (landed Builds record `true`/`false`).

### Shaping an Intent from a task statement

Run `kogen intent shape <slug> <file> --project <checkout>` to create `.kogen/intents/<slug>/intent.md` and `.kogen/acceptance/<slug>_test.exs`. Pass `-` as the file to read the request from stdin. The command blocks until shaping and validation finish, with a 60-turn limit and no wall timeout; it never approves the Intent. When shaping ends on a provider error after its retries, it exits 4 and says that no Intent was written. Its model and effort come from `build.roles.shaper`, falling back to `build.roles.builder`; `--json` emits per-call usage for automation.

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
