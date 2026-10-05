# Kogen end-to-end demo

Archived 2026-10-03 transcript using the pre-settled CLI. It records historical behavior; use the current commands in [README](../README.md).

Recorded 2026-10-03. Live provider credential source: `codex_borrowed` (the existing Codex auth file; no credential copied into the project). Both approvals used the supplied provenance:

```text
claude, delegated by Almir: 'In the morning I'd like to see the core working' / 'you can even try building on top of P0 using P0'
```

## 1. External hello_app fixture

Create a bare origin and seed checkout:

```console
$ make demo-fixture
warning: You appear to have cloned an empty repository.
origin=/Users/almirsarajcic/Areas/Kogen/kogen-demo/hello_app-origin-20261003012348-3434.git
seed=/Users/almirsarajcic/Areas/Kogen/kogen-demo/hello_app
```

The seed commit was `4c9053194b463ad0b6143b82583c198f3a36cc4a`. The demo used the installed escript from generation `e1909ad3ba9930284e7d09349d40585b80b3af59`.

Check and approve the `greet` Intent:

```console
$ "$HOME/.local/bin/kogen" intent check .kogen/intents/greet/intent.md --project "$HOME/Areas/Kogen/kogen-demo/hello_app" --origin "$HOME/Areas/Kogen/kogen-demo/hello_app-origin-20261003012348-3434.git" --base main
intent greet: valid (sha256 4f276a1db7956cb8e445cea065cb22624c4c1c7edfb2f1c9e925d3dae1000058)

$ "$HOME/.local/bin/kogen" approve greet --project "$HOME/Areas/Kogen/kogen-demo/hello_app" --origin "$HOME/Areas/Kogen/kogen-demo/hello_app-origin-20261003012348-3434.git" --base main --yes --by "claude, delegated by Almir: 'In the morning I'd like to see the core working' / 'you can even try building on top of P0 using P0'"
Intent: greet — Add greetings in English and Bosnian
SHA-256: 4f276a1db7956cb8e445cea065cb22624c4c1c7edfb2f1c9e925d3dae1000058
Approved by: claude, delegated by Almir: 'In the morning I'd like to see the core working' / 'you can even try building on top of P0 using P0'
Base: main at 4c9053194b463ad0b6143b82583c198f3a36cc4a

Brief
  Add `HelloApp.Greeter.greet/2` with English and Bosnian greetings. Unsupported languages return `{:error, :unsupported_language}`.

Acceptance
  - [A1] `HelloApp.Greeter.greet("Almir", :en)` returns `"Hello, Almir!"`. (test)
  - [A2] `HelloApp.Greeter.greet("Almir", :bs)` returns `"Zdravo, Almir!"`. (test)
  - [A3] `HelloApp.Greeter.greet("Almir", :fr)` returns `{:error, :unsupported_language}`. (test)
approved: 9a216c31c2ab1e62f7fd275b17f1fc73e271e04b
```

Build with the live `gpt-6-luna` provider at max effort:

```console
$ "$HOME/.local/bin/kogen" build greet --project "$HOME/Areas/Kogen/kogen-demo/hello_app" --origin "$HOME/Areas/Kogen/kogen-demo/hello_app-origin-20261003012348-3434.git" --base main --model gpt-6-luna --effort max
run: 0640c09c61c5ef740870ab981838b188
context: complete
plan: complete
develop: done
fix: complete
checks + acceptance: pass
review: accept
commit: ae0de1fb67dbe3d5805ce530a5ec191e42ffdadc
land: complete
land: landed ae0de1fb67dbe3d5805ce530a5ec191e42ffdadc
run dir: /Users/almirsarajcic/Areas/Kogen/kogen-demo/hello_app/.kogen/runs/0640c09c61c5ef740870ab981838b188
```

The landed commit trailers were:

```text
Kogen-Intent: greet
Kogen-Run: 0640c09c61c5ef740870ab981838b188
Kogen-Approval: 9a216c31c2ab1e62f7fd275b17f1fc73e271e04b
Kogen-Receipt: 90451f1a526b815723e8fbd9c9d4fc5b0c909396
```

The final status and JSON report came from the newly installed `9898473a1c26502e0d738453697dba0b3df6e210` escript:

```console
$ "$HOME/.local/bin/kogen" status --project "$HOME/Areas/Kogen/kogen-demo/hello_app" --origin "$HOME/Areas/Kogen/kogen-demo/hello_app-origin-20261003012348-3434.git" --base main --json
[{"landed_sha":"ae0de1fb67dbe3d5805ce530a5ec191e42ffdadc","run_id":"0640c09c61c5ef740870ab981838b188","slug":"greet","status":"landed"}]

$ "$HOME/.local/bin/kogen" report greet --json --project "$HOME/Areas/Kogen/kogen-demo/hello_app" --origin "$HOME/Areas/Kogen/kogen-demo/hello_app-origin-20261003012348-3434.git" --base main
{"acceptance_results":[{"status":"passed","tag":"greet/A2","test":"test greets in Bosnian"},{"status":"passed","tag":"greet/A1","test":"test greets in English"},{"status":"passed","tag":"greet/A3","test":"test returns an error for an unsupported language"}],"approval":"9a216c31c2ab1e62f7fd275b17f1fc73e271e04b","base":"4c9053194b463ad0b6143b82583c198f3a36cc4a","candidate":"ae0de1fb67dbe3d5805ce530a5ec191e42ffdadc","check_receipts":[{"at":"2026-10-02T23:07:38Z","check":"check","exit_status":0,"log_sha256":"1c23c395380d3f516af5c5ecbce3d77140b87f379a2b699f8bd85fdc1513ad80","tree":"90451f1a526b815723e8fbd9c9d4fc5b0c909396"}],"failures":[],"landed_sha":"ae0de1fb67dbe3d5805ce530a5ec191e42ffdadc","model_stages":[{"effort":"low","model":"gpt-6-luna","stage":"context","tokens":{"cache_write":0,"cached_input":0,"input":4743,"output":483,"reasoning":0}},{"effort":"max","model":"gpt-6-luna","stage":"plan","tokens":{"cached_input":0,"input":2593,"output":224,"reasoning":142}},{"effort":"max","model":"gpt-6-luna","stage":"develop","tokens":{"cache_write":0,"cached_input":0,"input":8342,"output":692,"reasoning":232}},{"effort":"max","model":"gpt-6-luna","stage":"review","tokens":{"cached_input":0,"input":732,"output":75,"reasoning":59}}],"slug":"greet","status":"landed"}
```

## 2. Self-improvement on `careful-rebuild`

The main checkout was detached to free `careful-rebuild` for compare-and-swap landing. The branch was fast-forwarded to the T10 core baseline (the baseline deliberately had text-only `status` so this Intent produced a real change), and the checkout remained detached:

```console
$ git switch --detach
HEAD is now at efe53d40 Build Kogen Developer harness stages

$ git branch --force careful-rebuild p0/T10
$ git switch --detach p0/T10
HEAD is now at 513cbabd Reserve JSON status for the self demo
```

The first build exposed a Kernel compatibility bug: `:escript.script_name/0` returned `-e` under the acceptance test's `elixir -e` runner. That non-file name was being treated as a script path. The Kernel now ignores script names that are not files. The failed attempt was run `5fc7bcf1b4c78495aed7cd2f8f531cd4`; its run record and approval commit `fde8bcd2b8cc6d6d1f440e77fe827c1379da2deb` were retained. The original approval was archived at `refs/kogen/archive/intents/status-json/fde8bcd2b8cc6d6d1f440e77fe827c1379da2deb`, `careful-rebuild` advanced to runtime-fix commit `56a3f08f985623a2a00215bcab4024d0156f5d3d`, and the same Intent was reapproved against that base with the same provenance.

Approval and successful build:

```console
$ "$HOME/.local/bin/kogen" approve status-json --project "$HOME/Areas/Kogen/careful-rebuild" --origin "$HOME/Areas/Kogen/careful-rebuild" --base careful-rebuild --yes --by "claude, delegated by Almir: 'In the morning I'd like to see the core working' / 'you can even try building on top of P0 using P0'"
Intent: status-json — Print status as JSON
SHA-256: 330185d2058ee3921acb0cc4a07e21f8759a508f92fcd6ad1354507c00ec7e16
Approved by: claude, delegated by Almir: 'In the morning I'd like to see the core working' / 'you can even try building on top of P0 using P0'
Base: careful-rebuild at 56a3f08f985623a2a00215bcab4024d0156f5d3d

Brief
  Add `kogen status --json` so scripts can read current Intent status records from standard output.

Acceptance
  - [A1] `kogen status --json` prints a JSON array whose records contain `slug`, `status`, `run_id`, and `landed_sha`. (test)
approved: 98e3f6d88d08d3c91a7a1e543a9099b02169b75d

$ "$HOME/.local/bin/kogen" build status-json --project "$HOME/Areas/Kogen/careful-rebuild" --origin "$HOME/Areas/Kogen/careful-rebuild" --base careful-rebuild --model gpt-6-luna --effort max
run: 3da15cbc496bb518e20eb5c9082950f3
context: complete
plan: complete
develop: gate_red
repair: done_gate_red
develop: done
fix: complete
checks + acceptance: pass
review: accept
commit: 9898473a1c26502e0d738453697dba0b3df6e210
land: complete
land: landed 9898473a1c26502e0d738453697dba0b3df6e210
run dir: /Users/almirsarajcic/Areas/Kogen/careful-rebuild/.kogen/runs/3da15cbc496bb518e20eb5c9082950f3
```

The status-json landing trailers were:

```text
Kogen-Intent: status-json
Kogen-Run: 3da15cbc496bb518e20eb5c9082950f3
Kogen-Approval: 98e3f6d88d08d3c91a7a1e543a9099b02169b75d
Kogen-Receipt: 585d0f1d9d20bebd6083ccf8702a9620a0060f26
```

Following the requested detached checkout and installation sequence:

```console
$ git switch --detach 9898473a1c26502e0d738453697dba0b3df6e210
HEAD is now at 9898473a Build status-json

$ make install-local
mise exec -- mix escript.build
Compiling 56 files (.ex)
Generated kogen app
Generated escript kogen with MIX_ENV=dev
installed: /Users/almirsarajcic/.kogen/gen/9898473a1c26502e0d738453697dba0b3df6e210/kogen

$ "$HOME/.local/bin/kogen" status --project "$HOME/Areas/Kogen/careful-rebuild" --origin "$HOME/Areas/Kogen/careful-rebuild" --base careful-rebuild --json
[{"landed_sha":"9898473a1c26502e0d738453697dba0b3df6e210","run_id":"3da15cbc496bb518e20eb5c9082950f3","slug":"status-json","status":"landed"}]
```

## 3. Guard and recovery demonstrations

Protected edits are rejected before checks run. The test edits a protected `checks.yml` and asserts a `:candidate/:protected_edit` failure:

```console
$ mise exec -- mix test --warnings-as-errors --no-compile test/kernel/build_guard_test.exs
Running ExUnit with seed: 221896, max_cases: 24

.
Finished in 0.3 seconds (0.3s async, 0.00s sync)

Result: 1 passed
```

The existing `greet` approval was also refused after its base moved:

```console
$ "$HOME/.local/bin/kogen" build greet --project "$HOME/Areas/Kogen/kogen-demo/hello_app" --origin "$HOME/Areas/Kogen/kogen-demo/hello_app-origin-20261003012348-3434.git" --base main --model gpt-6-luna --effort max
environment/base_moved: expected 4c9053194b463ad0b6143b82583c198f3a36cc4a, found "ae0de1fb67dbe3d5805ce530a5ec191e42ffdadc"
exit: 3
```

To simulate a crash after CAS, the landed run journal was moved back to `running`, its claim was recreated, then the installed CLI reconciled against the already-landed branch:

```console
$ mise exec -- mix run -e 'project = "/Users/almirsarajcic/Areas/Kogen/careful-rebuild"; run_id = "3da15cbc496bb518e20eb5c9082950f3"; {:ok, runtime} = Kogen.Kernel.runtime(); {:ok, process_env} = Kogen.Kernel.project_environment(project, runtime); git_env = Kogen.Kernel.Runtime.git_environment(process_env); root = Path.join(project, ".kogen"); {:ok, run} = Kogen.State.load(root, run_id); :ok = Kogen.State.record(run, %{event: :crash_simulated, status: :running}); :ok = Kogen.State.claim(project, run_id, git_env); IO.puts("simulated crash after CAS: " <> run_id)'
simulated crash after CAS: 3da15cbc496bb518e20eb5c9082950f3

$ "$HOME/.local/bin/kogen" reconcile 3da15cbc496bb518e20eb5c9082950f3 --project "$HOME/Areas/Kogen/careful-rebuild" --origin "$HOME/Areas/Kogen/careful-rebuild" --base careful-rebuild
reconcile: landed
```

## Verification

At the self-demo snapshot, before the local gate was split, `make check` finished with `Result: 150 passed, 2 excluded` and `check OK`. The current full gate is `make check-full`; `make integration` uses it before the fixture check. The standalone protected-edit test finished with `Result: 1 passed`.
