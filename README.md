# Kogen

Kogen is an AI-agent software-building system written in Elixir. A human approves a short Markdown Intent; Kogen builds it in an isolated checkout with an LLM Developer loop, verifies the result with deterministic checks, and lands it on the selected base branch.

This repository is the single Mix application that forms Kogen's core. Kogen owns its ChatGPT logins, which belong to the machine: `kogen provider use` picks the default account and, optionally, one per project. Each project's `.kogen/project.yaml` selects its base branch, Build recipe, and role models. Build receipts record the selected account and model settings. Approval records the baseline of red project checks and warns instead of blocking.

## Start here

- [Contracts](lib/kogen/contracts.ex) defines the shared structs and ports.
- [Domain facades](lib/kogen/) own the dependency map and document each domain.
- [CLI interfaces](docs/interfaces.md#kogenkernel-and-cli) documents command contracts and project settings.
- [Makefile](Makefile) owns the local quality gate and fast domain loop.
- [Distribution and local installation](docs/distribution.md) describes the installed launcher and its pinned runtime.
- [Custom Credo checks](tools/kogen_checks/) owns Kogen-specific static checks.

## CLI

Commands are noun-first. `kogen` lists the commands, `kogen <command>` lists its subcommands, and `--help` works everywhere. Approved Intents build through the queue, one at a time; crashed Builds are recovered automatically by `status` and `queue start`.

```sh
kogen intent shape greet request.md   # or - to read the request from stdin
kogen intent approve greet            # review card with the hash; exits 5
kogen intent approve greet 3fa2c1d0   # approve exactly what you reviewed; queues it
kogen queue start                     # build the queue in the foreground (--detach for background)
kogen status                          # queue, then Intents by state
kogen status greet                    # one Intent and its latest Build (--json for the report)
kogen provider use chatgpt --as work --project .
```

The full tree, output and exit codes are in [docs/interfaces.md](docs/interfaces.md#command-line).

Build settings belong in `.kogen/project.yaml`:

```yaml
base: main
build:
  recipe: ladder        # the default; also ladder-diverse, ladder-luna, ladder-sol-medium, plan-shell, ...
  wall_minutes: 60      # a ladder's whole-Build budget
  edge_tests: false     # true (or a ladder recipe with a +edge suffix) runs the edge probe
  model_fallback: true # false keeps overload retries on the selected model
  roles:
    builder:
      model: gpt-6-luna
      effort: max
    planner:
      model: gpt-6.1-sol
      effort: high
```

The `ladder` recipe plans once, then builds on fresh Candidates rung by rung (configured builder, Sol medium, Sol high, then a raw-request attempt) until one is green, repairing while failures fall. A hard plan runs the first two rungs in parallel; when both are green, each runs the other's new tests and the one passing more of them lands (then fewer gate warnings, then the smaller diff). A test auditor can demote an acceptance test that is over-strict or contradicts the Request. With `edge_tests: true`, the first green Candidates also face up to 20 black-box edge tests that the builder model writes from the verbatim Request; tests every Candidate fails are discarded, the rest rank green Candidates after the cross-check, and a lone green Candidate that fails some gets one repair round whose result competes with it. Edge tests never block landing. When no rung is green, the best Candidate is pushed to `kogen/<slug>` and status shows `needs attention: kogen/<slug>`.

Intent shaping defaults to **gpt-6.1-sol at high effort**, independently of the builder model. An explicit `build.roles.shaper` in `.kogen/project.yaml` or `~/.kogen/config.yaml` overrides this default; project fields take precedence over machine settings.

Builder ladders `ladder-luna`, `ladder-sol-low`, `ladder-sol-medium`, and `ladder-sol-high` keep every builder attempt, including fresh and raw-request rungs and overload retries, on their named model and effort. Luna uses `gpt-6-luna` at max; the Sol variants use `gpt-6.1-sol` at low, medium, or high. Their planner, acceptance-test auditor, and edge-test writer use Sol high. Builder role overrides do not change these recipes.

For benchmarks on one model, use `ladder-luna`, `ladder-sol-low`, `ladder-sol-medium`, or `ladder-sol-high` with `KOGEN_BENCH_NO_FALLBACK=1`. This overrides project and machine `build.model_fallback` settings, keeps overload retries on the same model and effort with backoff until the Build's wall budget runs out, and records `model_fallback: false` in the run journal, status report and benchmark `usage.json`. Projects can also set `build.model_fallback: false`. Fallback remains enabled by default; shaping without a wall budget still stops at its retry limit.

When `base` is omitted, Kogen uses the origin HEAD branch recorded locally, then the checkout's current branch. Optional machine defaults live in `~/.kogen/config.yaml`; project settings override them.

## Repository map

| Path | Contents |
| --- | --- |
| `lib/kogen/` | Contracts, domain facades, and the future core modules |
| `test/` | ExUnit tests, `Kogen.Testkit`, and [scrubbed gate feedback fixtures](test/fixtures/gate_feedback/README.md) |
| `tools/kogen_checks/` | The local Credo check package and its tests |
| `bin/kogen-bench`, `bin/kogen-format-check` | Held-out runner and changed-file formatter gate |

## Domains

| Domain | Responsibility | Depends on |
| --- | --- | --- |
| Contracts | Shared value types and port behaviours | — |
| Proc | Bounded operating-system process execution | Contracts |
| HTTP | Bounded OTP HTTP requests and HTTPS proxy tunnelling | — |
| Project | Project configuration and check definitions | Contracts |
| Intent | Human-authored Intent loading and validation | Contracts |
| Provider | Model-provider requests and responses | Contracts, HTTP, Proc |
| Build | Developer loop and candidate lifecycle | Contracts |
| Workspace | Isolated checkout and worktree operations | Contracts, Proc |
| State | Persisted build state and receipts | Contracts, Workspace |
| Checks | Deterministic verification and check results | Contracts, Proc, Workspace, Project |
| Tooling | Builder tool schemas, confined file access, edits, search, writes, and shell commands | Contracts, Proc |
| Harness | Provider-backed Developer orchestration and stage coordination | Checks, Contracts, Proc, Provider, Project, Tooling |
| Engine | Single-Candidate Build stages, checks, commit, landing and cleanup | Build, Checks, Contracts, Harness, Intent, Proc, Project, Provider, Resilience, State, Workspace |
| Runner | Drives the Build Cycle across Candidates: ladder rungs, parallel members, test auditor | Build, Checks, Contracts, Engine, Harness, State |
| Queue | Intent states, the serial drain and its lock, automatic crash recovery, Build reports | Proc, State, Workspace |
| CLI | Command parsing and static help (pure) | — |
| Kernel | Command execution and cross-domain coordination | Every domain above |

## Run the checks

Use the pinned toolchain from `mise.toml`:

```sh
mise exec -- mix deps.get
make check
make check-full
make check-fast D=contracts
```

`make check` runs formatting, the guard, strict compilation, xref, Credo, unit and acceptance tests, and Dialyzer. `make check-full` runs that gate plus the e2e suite; `make integration` uses `check-full` before the fixture integration check. Use `check-full` for landing and nightly gates. `make check-fast D=<domain>` scopes Credo and ExUnit to one domain after compiling the app.

## Toolchain and layout

Elixir 1.20.4-otp-29 and Erlang/OTP 29.1.1 are pinned in `mise.toml`. The repository is one Mix app named `kogen`; domain modules live in `lib/kogen/`, tests in `test/`, test support in `test/support/`, and local static-analysis checks in `tools/kogen_checks/`.
