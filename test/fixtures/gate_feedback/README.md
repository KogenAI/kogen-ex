# Gate feedback fixtures

These are copies of noisy check output used by `Kogen.Checks.FeedbackTest`. Raw source logs remain in their original run directories. Paths were reduced to project-relative names or `$WORKDIR`; temporary directories and process IDs were scrubbed.

The compiler, ExUnit, format, and aggregate gate samples came from real run logs:

| Fixture | Source under `~/.kogen/workspaces/` |
| --- | --- |
| `compile-35.log` | `careful-rebuild-04998ef811/runs/f2667c7411aceebafd0830127e5befae/logs/diagnose-35.log` |
| `gate-format-42.log` | `project-4c4fe1c45b/runs/baf62ccc5689c7f951204fc0d63081c9/logs/gate-check-format-42.log` |
| `gate-tests-41.log` | `project-4c4fe1c45b/runs/baf62ccc5689c7f951204fc0d63081c9/logs/gate-check-tests-41.log` |
| `gate-full-46.log` | `careful-rebuild-04998ef811/runs/dbcad4ce6a57af032013d30989970de9/logs/gate-check-full-46.log` |
| `gate-full-97.log` | `careful-rebuild-04998ef811/runs/f2667c7411aceebafd0830127e5befae/logs/gate-check-full-97.log` |
| `gate-full-49.log`, `gate-full-59.log` | `careful-rebuild-04998ef811/runs/5deb67c67617580b1126dcbbb2df4d65/logs/gate-check-full-49.log` and `...gate-check-full-59.log` |

`gate-benchmark-tests.log` is a successful ExUnit tool-output excerpt from the 1 October 2026 benchmark cell `p2-syn18flakysuite-codex-r1`, at `benchmark-night-2026-10-01/results/p2-syn18flakysuite-codex-r1/codex__gpt-6-luna__max__default__syn-18-flaky-suite__r1/attempt-1/rollout.jsonl`. It retains the progress dots and build-lock chatter while scrubbing the process IDs.

## Five red-gate size samples

“Before” is the old gate payload (`<step> exited <status>.` plus at most the last 10,000 raw-output characters). “After” is the new model-facing payload. Environment-level failures are withheld from the model, so their after count is zero. Counts use Elixir string characters.

| Source | Exit level | Before | After |
| --- | ---: | ---: | ---: |
| `gate-full-46.log` | 3 | 10,021 | 0 |
| `gate-full-97.log` | 1 | 5,682 | 967 |
| `gate-full-59.log` | 3 | 10,021 | 0 |
| `gate-full-49.log` | 3 | 10,021 | 0 |
| `gate-format-42.log` | 1 | 2,553 | 772 |
| **Total** |  | **38,298** | **1,739 (95.5% lower)** |

The reduction test recomputes these payload sizes from the checked-in fixtures and verifies the compact form stays below one quarter of the old payload.
