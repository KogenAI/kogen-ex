# Kogen

Kogen is an AI-agent software-building system written in Elixir. A human approves a short Markdown Intent; Kogen builds it in an isolated checkout with an LLM Developer loop, verifies the result with deterministic checks, and lands it on the main branch.

This repository is the single Mix application that forms Kogen's core. Current work extends its domain foundation with account-scoped ChatGPT login, explicit credential selection, and credential-aware Build receipts.

## Start here

- [Contracts](lib/kogen/contracts.ex) defines the shared structs and ports.
- [Domain facades](lib/kogen/) own the dependency map and document each domain.
- [Makefile](Makefile) owns the local quality gate and fast domain loop.
- [Custom Credo checks](tools/kogen_checks/) owns Kogen-specific static checks.

## Repository map

| Path | Contents |
| --- | --- |
| `lib/kogen/` | Contracts, domain facades, and the future core modules |
| `test/` | ExUnit tests, `Kogen.Testkit`, and [scrubbed gate feedback fixtures](test/fixtures/gate_feedback/README.md) |
| `tools/kogen_checks/` | The local Credo check package and its tests |
| `bin/kogen-bench` | Held-out benchmark runner for approved Build tasks |

## Domains

| Domain | Responsibility | Depends on |
| --- | --- | --- |
| Contracts | Shared value types and port behaviours | — |
| Proc | Bounded operating-system process execution | Contracts |
| Project | Project configuration and check definitions | Contracts |
| Intent | Human-authored Intent loading and validation | Contracts |
| Provider | Model-provider requests and responses | Contracts, Proc |
| Build | Developer loop and candidate lifecycle | Contracts |
| Workspace | Isolated checkout and worktree operations | Contracts, Proc |
| State | Persisted build state and receipts | Contracts, Workspace |
| Checks | Deterministic verification and check results | Contracts, Proc, Workspace, Project |
| Tooling | Builder tool schemas, confined file access, edits, search, writes, and shell commands | Contracts, Proc |
| Harness | Provider-backed Developer orchestration and stage coordination | Checks, Contracts, Proc, Provider, Project, Tooling |
| Kernel | CLI and cross-domain coordination | Every domain above |

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
