---
title: Declare gate changes while shaping
domains: [shaper, harness, checks, project]
size: small
---
A request that plans to change a project gate file currently produces an Intent without `changes_gate: true`, so Builds restore the protected file repeatedly and fail. Teach shaping when the flag applies, and reject missing declarations when the Intent's approach or acceptance test indicates a gate-file edit; unrelated changes remain unflagged.

## Acceptance
- A1: The prompt directs `changes_gate: true` only for gate-path changes, and shaped gate requests are flagged while unrelated requests remain unflagged.
- A2: Shape validation rejects Notes naming `Makefile` without `changes_gate: true` and reports `Makefile`.
- A3: Shape validation rejects an acceptance test writing `.credo.exs` without `changes_gate: true` and reports `.credo.exs`.

## Verify
- A1: test domain=shaper
- A2: test domain=shaper
- A3: test domain=checks

## Notes
Approach: Expose effective paths through `Kogen.Project.GatePaths`, include them and the flag rule in `Kogen.Harness.Shaping.input_items/6`, then check Intent Notes and acceptance bytes in `Kogen.Shaper.Validation` and `Kogen.Checks.Shaping.validate/1`. Report the matched path; keep unrelated Intents unflagged.

## Request
When a request requires changing the project's gate configuration (the configured checks in .kogen/project.yaml, gate_paths such as the Makefile check targets, .credo.exs, .formatter.exs, .dialyzer_ignore.exs, or tools/), the shaped Intent must declare `changes_gate: true` in its frontmatter; otherwise the Build keeps restoring those protected files and fails with protected_restore_limit. Today the shaper never sets it.
Make the shaper set changes_gate: true exactly when the task statement or its planned changes touch gate paths, explain it in the shaping prompt, and make Intent validation reject an Intent whose acceptance tests or approach require editing a gate path without changes_gate: true, with a message naming the path.
