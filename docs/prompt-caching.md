# Prompt caching

## Diagnosis and token accounting

Kogen's `requests.jsonl` **input excludes cached tokens**. The Responses encoder
normalizes provider usage as `input = input_tokens - cached_tokens`. Therefore:

```
total_input = input + cached_input
cache_hit_rate = sum(cached_input) / sum(input + cached_input)
```

Output and reasoning-output tokens are outside that denominator. No measured input
means `null`, rather than a fabricated zero or perfect hit. Status includes finished
model stages and the journal's unrecorded partial usage once, including failed Builds.
Benchmark `usage.json` reports the Build rate, excluding the preceding shape command.

The local journals inspected on 2026-10-06 contained 1,584 requests with reported
input: 48,701,623 uncached and 34,296,192 cached tokens, a **41.32%** weighted rate.
Develop accounted for 1,565 of those requests; plan and audit had no cached tokens.
The offline release calculator found 42 measurable legacy develop groups: the median
of their conversation medians was zero and none reached 0.95.
This local corpus is different from the team's r74 corpus (4,330 requests, 26.5%
overall; develop 27.3%, shape 18.5%, plan/audit 0%). Dividing cached by Kogen input
alone substantially overstates either result. Only token/count fields were read;
no credentials or live provider calls were used.

The benchmark team's consecutive develop requests already had append-only history
(+3 items per turn) and unchanged fronts. Random zeros interspersed with nearly full
reuse are evidence of missing affinity, rather than evidence of rewritten history.
Kogen already sent a body `prompt_cache_key`, but hashed only run directory and stage:
parallel conversations in one Build could collide. It sent no session routing header.

[Codex's client](https://github.com/openai/codex/blob/960e878df4bf87b9d7fa0849f14561d7cdcca942/codex-rs/core/src/client.rs)
explicitly states that ChatGPT derives cache affinity from the Responses `session-id`
header. `prompt_cache_key()` normally returns the conversation session id (or an
explicit override; internal agents can derive a key from source and parent thread).
The root Responses session header uses that cache key.
[Its header builder](https://github.com/openai/codex/blob/960e878df4bf87b9d7fa0849f14561d7cdcca942/codex-rs/codex-api/src/requests/headers.rs)
sends `session-id` and `thread-id`, not `session_id`/`conversation_id` body fields.
The local source revision above was inspected and these functions were also verified
against upstream `main`. Codex also carries server-provided `x-codex-turn-state` within
a turn and supports incremental WebSocket requests. Kogen uses full-history HTTP SSE;
that turn-scoped optimization is separate from stable conversation affinity.

[OpenAI's caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
requires matching prompt prefixes and describes model-dependent cache behavior.
Public API routing guidance alone does not establish the ChatGPT backend's header
contract; the Codex implementation is the evidence for this transport change.

## Wire invariants

Every harness request now uses a SHA-256 key over the expanded run directory, stage,
attempt, rung and context epoch, with explicit separators and a versioned namespace. It is stable
across turns, retries and same-session repairs. Builder and fresh-N use distinct keys.
The exact key is sent in `prompt_cache_key`, `session-id` and `thread-id`, for both
Codex and owned ChatGPT transports, including Lite. It is also recorded as
`conversation_id` in the request journal, without adding any CLI commands or options.
Lite keeps a separate run-level `session_id` (underscore header and request setting)
for its protocol identity. That value is not the per-rung affinity key.

Instructions and tool schema order stay fixed. Approved Intent and plan advice lead
the history; responses (including opaque reasoning items), tool outputs, failures,
protected-file feedback and budget reminders append to it. Deadlines and request
budgets remain controller metadata, never changing the instructions. The former
80%-of-turn-budget reminder briefly changed the instructions and disappeared on the
next turn. It now appends once to history and remains present on subsequent turns.

The JSON envelope now serializes static controls before the growing `input` array.
Both encoders preserve every existing history item without rewriting its fields.
The Codex encoder requests `reasoning.encrypted_content`; the owned SIWC encoder
retains returned reasoning but keeps its existing supported schema, which omits
`include`. Both use `store: false` and explicit full history; the harness never sets
`previous_response_id`. Enabling storage or chaining stored responses is unnecessary
for prompt caching and would change the persistence contract.

A complete closed JSON request cannot literally be a byte prefix of another valid
closed JSON request with appended array elements. The wire test removes **only** the
final `]}` framing and asserts that the next actual encoded request starts with every
remaining byte of the previous one. All envelope fields, instructions, tools, Intent,
plan and history are covered. At the first difference, the old array closer `]` is
replaced by the new item separator `,`; the old history itself is identical. This is
stronger than searching for the previous input somewhere inside a later body.
HTTP Content-Length also necessarily changes and is outside the model prompt.

`test/harness/prompt_caching_test.exs` replays three-turn conversations through both
encoders for develop, plan, context and shape, retains encrypted reasoning, checks
rung isolation and same-session repairs, and crosses the late budget reminder.
The transport test captures real loopback HTTP bytes and checks both routing headers
against the body key. No live service is involved.

## Per-stage findings

| Stage | Prefix and conversation behavior |
| --- | --- |
| Develop | Fixed developer instructions and tool recipe; approved Intent/plan first; history appended verbatim. Missing session affinity was the primary defect. Late budget instructions were a second prefix break. |
| Repair | Same developer conversation and key; controller failures append after prior response/history. Repair counters do not rewrite retained authority. |
| Fresh / parallel rung | New history, model/recipe and attempt; distinct affinity key. Deliberately independent from builder and other rungs. |
| Plan | Read-only tool loop already appends responses and results. Fixed tools/instructions and stable stage/attempt/rung key. The ls-files recipe is a single call and cannot have a warm within-stage turn. |
| Context | Read-only loop already appends; fixed instructions/tools. Separate model/task from planner and developer, so its prefix cannot be reused as their full conversation. |
| Shape / shape repair | Fixed stack-specific instructions and ordered tool specs. Domain names are sorted. Task/slug/paths are initial user content; validation failures append after retained history with the same key. |
| Review / audit | Distinct role instructions, no tools, changing candidate/check evidence after the Intent. Usually single calls; a new role cannot reuse a developer conversation's full prefix. |
| Edge | Independent role and test-writing authority. Evidence follows its role's static instructions. It is not a continuation of the developer's tool conversation. |
| Opt-in context checkpoint | An intentional bounded-context reset, documented in `build-continuation.md`: summarizer instructions/tools differ, then compact history replaces the old transcript. Full previous-prefix reuse is impossible across this boundary. The summarizer has a separate key; compacted history starts a new cache epoch. This feature is disabled unless `build.context_bytes` is configured. |
| Mutation advice | Post-gate advice changes instructions and removes tools. It has a separate key from develop, avoiding contamination of the warm-conversation metric. It remains advisory and cannot edit the candidate. |
| Model fallback | A changed model has a different cache. Encrypted reasoning from the old model is intentionally removed for compatibility. Same-model retries retain bytes and affinity. |

Stages with compatible conversations (normal tool turns, same-session developer
repair and shape repair) share their prefixes and keys. Sharing a key across roles
with different instructions/tools would not make their prefixes equal. Retaining
separate role authority avoids weakening the planner/auditor/edge contracts.

## Release measurement

`kogen status <slug> --json` and benchmark `usage.json` expose `cache_hit_rate` as a
0–1 fraction. For the separate warm-conversation release metric, run offline:

```sh
python3 tools/prompt_cache_report.py '/path/to/runs/*/requests.jsonl'
```

For each develop conversation, the report computes the median of
`cached_input(n) / (input(n-1) + cached_input(n-1))` from its third successful
request onward and reports whether it reaches **0.95**. It preserves journal order
when a repair restarts the harness turn counter, excludes failed calls with no usage,
and excludes comparisons across model changes. Tool-result receipts in the same
journal are ignored. Legacy journals without ids or record kinds are grouped by
file/attempt/rung; they cannot reliably distinguish context checkpoints.
Cache alignment can cause small differences from exact reuse; newly appended tokens
also mean this ratio and the Build-wide hit rate measure different things.

The scripted tests prove affinity fields and prefix stability, not server cache hits.
No post-change live cache measurement was made under the no-provider-call constraint.
The >=95% release target must be validated with a subsequent benchmark; it cannot be
guaranteed by local wire tests or manufactured from scripted usage counters.
