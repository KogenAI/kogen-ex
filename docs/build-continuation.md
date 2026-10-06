# Build context continuation

Set `build.context_bytes` in `.kogen/project.yaml` to opt into checkpoint continuation
(minimum 16000). The number is serialized history bytes, a conservative caller-selected
threshold, **not** a token count or a claim about any model's context window. Leave room
for instructions, tools, output and the checkpoint request itself. Omission keeps the
existing loop. Machine defaults do not currently enable this experimental policy.

Before the next Developer turn, the same builder makes a no-tool checkpoint request.
The checkpoint must include obligations, findings, useful investigation, ruled-out
approaches with reasons, and next steps. The next conversation starts with the original
approved request and plan, verbatim, plus that checkpoint. The worktree, approval, turn
and wall budgets, repair policy and done gate continue unchanged. Full investigation
and each model request remain in `transcript.jsonl`; accepted checkpoints are written to
`continuation-<turn>-<id>.md`. No tool call is carried without its result. Invalid, empty or
oversized checkpoints stop with `continuation_failed` instead of silently discarding
history. A checkpoint consumes wall budget and its usage is in the request journal.
The `context_continued` receipt records before/after bytes and the checkpoint path;
`kogen status <slug>` reports how many continuations the same Build used.

## Reproducible qualification

Run `mise exec -- mix test test/harness/continuation_test.exs`. It writes and prints a
JSON comparison of the current loop and checkpoint loop. Both replay long investigations
with a disproven API replacement, a return-shape finding, a preserved public API
obligation, and a final delivered file. The scenarios simulate context pressure during
return-shape and dispatch investigations. They are scripted provider stress tests, not
live model evaluations or evidence of general success on hard repositories. Tokens below
are estimates (serialized input bytes / 4), including checkpoint requests; output and
provider tokenization are not measured. Repeated work is repeated investigation steps.

| Per scenario | Delivered | Estimated input tokens | Repeated investigation |
| --- | --- | ---: | ---: |
| Current, 32000-byte simulated context | no | 65592 | 0 |
| Current, unlimited simulated context | yes | 98092 | 0 |
| Checkpoint at 16000 bytes, same 32000-byte limit | yes | 35132 | 0 |

The checkpoint loop delivers the fixture under its limit and uses about 64% less input
than the successful unlimited control. This supports keeping an **opt-in experimental**
policy. It does not justify making it the default: a live comparison on long hard Builds
must still measure delivered acceptance success, actual input/output tokens, wall time,
and repeated or forgotten work. Model summaries can omit investigation despite a valid
shape; the verbatim approval and complete transcript are the recovery anchors.
