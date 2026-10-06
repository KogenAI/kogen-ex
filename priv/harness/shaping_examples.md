These are two real accepted Intents from Kogen's `careful-rebuild` history. Copy their concise structure and specificity; do not copy their scope or domain names into the new Intent.

Accepted example 1: `.kogen/intents/approval-checks/intent.md`
```markdown
---
title: Check acceptance tests at approval
domains: [project, contracts, kernel]
size: small
---
Three self-builds failed late because an approved acceptance test broke a static rule (a forbidden domain reference) that only the done gate checked. The Developer may not edit the test, so each Build was lost. Let a project declare `acceptance_checks:` that `kogen intent approve` runs on the acceptance test before it records an approval.

## Acceptance
- A1: `kogen intent approve` exits non-zero, names the failing check, and records no approval when an acceptance check fails.
- A2: When every acceptance check passes, `kogen intent approve` records the approval and leaves no check files in the checkout.
- A3: An `{path}` argv element is replaced by `test/acceptance/<slug>_test.exs`, which holds the acceptance test while checks run.

## Verify
- A1: test domain=kernel
- A2: test domain=kernel
- A3: test domain=kernel

## Notes
`acceptance_checks` uses the same entry shape as `checks` (name, argv, timeout_ms) and defaults to an empty list. Checks run in the project checkout with the project env. Refuse to run them if `test/acceptance/<slug>_test.exs` already exists with different bytes. Kogen's own project.yaml gets `mix credo --strict {path}` and a compile check in a later change, not in this Intent.
```

Accepted example 2: `.kogen/intents/land-on-moved-base/intent.md`
```markdown
---
title: Rebase onto a moved base instead of parking
domains: [engine, workspace, docs]
size: small
---
When the base branch gains commits while a Build runs, landing parks the Build and asks for a new approval, so a queue of Intents can land only one. When the base did not move, landing still re-runs the full checks and acceptance on the identical tree. Rebase the Candidate onto the new tip and verify it there before landing, and land directly when the base did not move.

## Acceptance
- A1: When the base gains a non-conflicting commit during a Build, the Build lands with that new tip as its commit's parent.
- A2: After rebasing onto a moved base, the last checks before landing run on exactly the tree that lands.
- A3: When the base did not move, the checks and acceptance run exactly once in the Build.

## Verify
- A1: test domain=engine
- A2: test domain=engine
- A3: test domain=engine

## Notes
A rebase conflict, or red checks after the rebase, still parks the Build as today. Update the existing e2e moved-base scenario to the new behaviour. The landing compare-and-swap stays as it is. `Kogen.Workspace.Checkout` is near its 400-line limit, so put new rebase code in its own small Workspace module.
```
