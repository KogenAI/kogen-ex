# Recovering long provider streams

Research date: 2026-10-06. Codex source inspected at
[`162fcb3976e292fb7492924f7d493fdfce328551`](https://github.com/openai/codex/tree/162fcb3976e292fb7492924f7d493fdfce328551).
Only public documentation/source and fake-token loopback/scripted providers were used.

## Finding and choice

The public Responses API documents background polling and cursor-based stream
recovery. The inspected Codex CLI instead retries sampling with the conversation
received so far. Neither its implementation nor the documentation inspected
establishes background retrieval/resume support for the ChatGPT-account Codex
backend. Consequently Kogen uses conversation replay on this path, rather than
assuming an undocumented GET endpoint or enabling background mode. This is a new
inference request continuing the turn, not recovery of the original server job.

## Public Responses API

With `background: true`, a response runs asynchronously and can be retrieved by ID
while its status is `queued` or `in_progress`. With `stream: true` as well, the client
retains the response ID and latest event `sequence_number`; after disconnection it
can issue `GET /v1/responses/{id}?stream=true&starting_after={sequence_number}`.
That is the preferred recovery mechanism when an endpoint explicitly supports it.
These examples use `api.openai.com` with API-key authorization; they do not establish
support on `chatgpt.com/backend-api/codex/responses`.
[Background mode](https://developers.openai.com/api/docs/guides/background).

`previous_response_id` chains context into a **new** response; it does not mean
“reattach to this unfinished generation.” Full input/output history can also be
supplied explicitly. For stateless reasoning, encrypted reasoning output can be
carried forward with the other output items.
[Conversation state](https://developers.openai.com/api/docs/guides/conversation-state).

WebSocket mode uses `previous_response_id` for incremental turns. Its documented
connection limit is 60 minutes. On reconnect, stored prior responses can provide
context; when that is unavailable (`store=false`, or a missing previous response),
the documented recovery is a new response with full context. This connection limit
is not a maximum duration for an SSE request on the ChatGPT backend.
[WebSocket mode](https://developers.openai.com/api/docs/guides/websocket-mode#connection-behavior-and-limits).

## Official Codex CLI

The provider definition identifies the ChatGPT backend base URL. Its defaults are
five stream retries and a 300,000 ms **idle** timeout, not a total stream-duration
limit.
[Provider definition](https://github.com/openai/codex/blob/162fcb3976e292fb7492924f7d493fdfce328551/codex-rs/model-provider-info/src/lib.rs).

Codex builds Responses requests with `store: false`, `stream: true`, and
`include: ["reasoning.encrypted_content"]`. The SSE client POSTs `/responses`
and parses events with the provider's idle timeout; it has no cursor retrieval
operation in this path.
[Request construction](https://github.com/openai/codex/blob/162fcb3976e292fb7492924f7d493fdfce328551/codex-rs/core/src/client.rs),
[SSE endpoint](https://github.com/openai/codex/blob/162fcb3976e292fb7492924f7d493fdfce328551/codex-rs/codex-api/src/endpoint/responses.rs).

Its sampling loop rebuilds the retry prompt from current session history. Completed
output items are recorded during streaming, and completed tool calls can execute
before the overall response finishes. Stream errors back off and retry sampling;
WebSocket retry exhaustion can switch to HTTPS.
[Sampling loop and output handling](https://github.com/openai/codex/blob/162fcb3976e292fb7492924f7d493fdfce328551/codex-rs/core/src/session/turn.rs),
[Conversation recording](https://github.com/openai/codex/blob/162fcb3976e292fb7492924f7d493fdfce328551/codex-rs/core/src/stream_events_utils.rs),
[Retry policy](https://github.com/openai/codex/blob/162fcb3976e292fb7492924f7d493fdfce328551/codex-rs/core/src/responses_retry.rs).

Codex's WebSocket optimization references a previous completed response and sends
only additional items when the prompt extends the known baseline. The completion
event supplies that baseline; an unfinished stream's ID alone does not enable it.
[WebSocket continuation and completion tracking](https://github.com/openai/codex/blob/162fcb3976e292fb7492924f7d493fdfce328551/codex-rs/core/src/client.rs).

No inspected official source documents a 900-second SSE maximum for this backend.
The r74 cuts at approximately 901–931 seconds despite continuing bytes and zero
proxy idle timeouts are consistent with an upstream duration cap, but that is a
benchmark inference, not a documented service limit. Raising an idle timeout would
not resolve such a cap. There is no basis here for claiming that background mode
is rejected either: its availability on this backend remains unverified, and live
capability probes were outside this task's permitted scope.

## Kogen behavior

Kogen's custom/benchmark ChatGPT configuration targets the Codex backend; owned
Sign-in-with-ChatGPT configuration targets the public Responses URL with a different
request codec. Both currently send stateless foreground streams. Recovery therefore
uses explicit context on both paths until background capability is established.

Events are decoded while bytes arrive. The watchdog retains partial assistant text,
completed encrypted reasoning, reasoning summaries, and proposed tool arguments.
On transport failure, missing completion, stall, or timeout, the replacement input
contains the original conversation, received progress, and a continuation instruction.
Repeated cuts accumulate progress. Model fallback drops encrypted reasoning from
the prior model. Successful output preserves the received answer prefix and replay
items so later Harness turns also retain the conversation.

Kogen executes tools only after a successful response. Interrupted tool proposals
are carried as notes explicitly stating that they were not executed; even completed
proposals must be reissued. This avoids dangling function-call/output pairs and
prevents partial arguments from causing side effects. Hidden reasoning that was
never emitted, incomplete SSE frames, and unreported usage cannot be recovered.
The replacement model can still repeat text or reasoning; replay is not exact server
resumption.

`requests.jsonl` remains one record per provider attempt:

- `cut_after_ms`: elapsed attempt milliseconds when a received stream is interrupted;
  null for success or a failure before any body byte.
- `resumed`: whether that attempt carries received progress from an earlier attempt.
  It means conversation continuation, not a background cursor reconnect.

The outer first-byte watchdog starts before provider setup and enforces 120 seconds
by default (or an explicitly smaller cap). This also covers waiting for Kogen's
shared HTTPS-profile lock, credential setup, and connection establishment, all of
which happen before the HTTP transport's own timer. Headers alone do not count as
body bytes; every nonempty body chunk, including keepalives, resets the idle timer.
A separate HTTP cancellation monitor closes outstanding requests when their receiver
is aborted. The HTTP total cap now also applies while awaiting the first byte.

Behavioral tests cover loopback cuts, partial text and tool arguments, encrypted
reasoning and summaries, repeated cuts, missing completion, actual socket cancellation,
and a scripted provider that emits no bytes and is aborted/retried at the real
120,000 ms cap. Existing tests exercise steadily progressing streams, deadlines,
ordinary retries, and model fallback.
