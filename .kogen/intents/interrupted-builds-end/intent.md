---
title: End interrupted Builds clearly
domains: [kernel, state, engine]
size: small
---
SIGTERM leaves a Build marked `building` after recording `interrupted`, so CLI views and benchmark reports misstate its outcome. Report `interrupted` in both views only when that event is last and its owner has exited; have `bin/kogen-bench` reconcile Builds exiting 143 before capturing `report.json`.

## Acceptance
- A1: After a dead owner’s last run event is `interrupted`, `build show <slug>` and `status --json` both report `interrupted`.
- A2: After `build` exits 143, `bin/kogen-bench` calls `kogen reconcile <run-id>` before writing `report.json`, which contains a terminal status.

## Verify
- A1: test domain=kernel
- A2: test domain=engine

## Notes
Approach: Use `Kogen.Kernel.StateView`'s event journal and `Reconcile`'s owner-PID liveness check when `Status` and `Report` render a run; keep live owners `building`. In `bin/kogen-bench`, extract the captured `run:` id and call `reconcile` only after exit 143, before the failure report; preserve ordinary failure handling.

## Request
When a Kogen Build is stopped with SIGTERM, the run stays marked `building`: the signal handler only appends an `interrupted` event, and nothing turns it into a terminal state until someone runs `kogen reconcile <run-id>`. bin/kogen-bench then writes a report that still says building.
Make interrupted Builds end clearly:
- `kogen build show <slug>` (and status) report an interrupted run as `interrupted`, not `building`, when its last event is `interrupted` and its owner process is gone.
- bin/kogen-bench runs `kogen reconcile <run-id>` after a Build exits 143, before writing report.json, so the report has a terminal status.
