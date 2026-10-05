---
title: Benchmark provided Intent input
domains: [engine]
size: small
---
Kogen's benchmark adapter always shapes from `prompt.md`, preventing comparison against a precise provided spec. Let `KOGEN_BENCH_INTENT_DIR` supply an Intent and acceptance test; copy both for the task slug, skip shaping, record the source, and preserve approval/build while runs without it still shape normally.

## Acceptance
- A1: With `KOGEN_BENCH_INTENT_DIR` set, the adapter copies both files for the task slug, skips shaping, records `provided`, and proceeds through approval and build.
- A2: Without the variable, the adapter shapes from `prompt.md`, proceeds through approval and build, and records `shaped`.

## Verify
- A1: test domain=engine
- A2: test domain=engine

## Notes
Approach: Change `bin/kogen-bench` where it currently captures `intent shape`: copy the supplied files to `.kogen/intents/$slug/intent.md` and `.kogen/acceptance/${slug}_test.exs` before continuing, then skip only shaping. Initialize and retain `intent_source` in initial, failed, and completed `usage.json` receipts, defaulting to `shaped`. Keep approval/build and prompt-driven shaping unchanged when the variable is unset.

## Request
Kogen's benchmark adapter (bin/kogen-bench) can only shape an Intent itself from the task's prompt.md. A benchmark round needs to give Kogen a ready-made Intent instead, to compare Kogen building from a provided precise spec against Kogen's own shaping.
Add an optional environment variable KOGEN_BENCH_INTENT_DIR pointing at a directory that contains intent.md and an acceptance test file. When it is set, kogen-bench copies them into the project as the Intent for the task's slug, skips shaping, records "intent_source": "provided" in usage.json (otherwise "shaped"), and continues with approval and build as today. When it is not set, behaviour is unchanged.
