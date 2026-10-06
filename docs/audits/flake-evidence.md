Flake evidence and repair workflow

A failed ExUnit check is rerun for the named tests with the same seed, followed
by a clean-base probe with the same argv and sandbox. A passing retry is excused
only for test identities that actually fail on that base. A passing, unavailable
or timed-out base cannot excuse it. Source reach guesses no longer grant green.
Persistent same-identity failures on Candidate and base retain the existing
base-red environment classification.

Each classification writes flake-evidence-*.json in the Build run directory:
test identities, Candidate/base results and logs, seeds, reproduction argv,
retry/probe time, base revision and Candidate path. A binary Candidate diff is
captured before retries when its base identity is available; the report says
when snapshot capture is unavailable. Reconstruct a scratch checkout at base_sha,
apply candidate_snapshot.patch for the Candidate reproduction, and run the
recorded Candidate argv. Run the recorded base argv without that patch on a
clean checkout at base_sha, using the approved project environment and sandbox.
Some flakes depend on external state; a command and seed cannot promise repro.
Evidence-recording failure keeps the check red.

Build JSON reports expose flake_evidence, named excused_flakes with their evidence,
flake_metrics, flake_fix_intents and flake_fix_failures. Two distinct Builds with
confirmed excused base failures for the same identity create a draft under
<state_root>/flake-fixes/flake-<identity-hash>/intent.md. Recurrence within one
Build does not trigger a draft. evidence.json is refreshed with all observations;
caller edits to an existing Intent are preserved. These files are outside the
approved queue: the caller reviews scope, supplies acceptance tests and approves
through the normal workflow. If project domains are absent the draft uses a
provisional test domain which the caller must correct. Draft-write failures are
reported and do not stop the started Build.

Metrics count observed classifications, confirmed excusals, distinct-Build
recurrence, rejected Candidate flakes, unconfirmed flakes, excused identities
without matching base evidence (leaks), and retry/probe milliseconds. Historical
receipts without evidence are counted separately. Invalid/unreadable historical
journals mark history incomplete. These are observation counts, not an estimate
of all undiscovered nondeterminism or proof that a passing Candidate cannot flake.

The existing two-distinct-test excusal cap is retained provisionally. Historical
proposals to stop a queue based on flake counts or rates have not been selected
as measured policy. No new queue-stop threshold or automatic approval is added.
Gather recurrence, leak evidence, delivery outcomes and retry costs from real
Builds before selecting stricter caps. Existing started-Build completion, ladder
budgets and terminal-failure rulings remain in force.
