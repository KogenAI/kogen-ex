---
title: Prevent duplicate queue runners
domains: [queue, cli]
size: small
---
`kogen queue start` can start a second drain while another is building an approved Intent; the second drain then claims the same Intent and fails it. A duplicate start must leave queue contents untouched, report the live runner's PID and start time, and exit successfully. Dead runner locks remain recoverable, and stop/status continue to work during an active drain.

## Acceptance
- A1: A concurrent `kogen queue start` exits 0, reports the live runner's PID and start time, and leaves the approved Intent and Build state unchanged.
- A2: A start with a dead runner PID takes over and automatically recovers the interrupted Build, releasing its claim.
- A3: `kogen queue stop` requests shutdown and `kogen status` reports the live runner while a drain is active.

## Verify
- A1: test domain=cli
- A2: test keep domain=queue
- A3: test keep domain=cli

## Notes
Approach: Update `Kogen.Queue.Lock` to expose the live runner's PID and persisted start time, and ensure `Drain.run/2` rejects an active owner before recovery, status, or build hooks run. Have `Kogen.Kernel.CLI.QueueCommand` report both values. Preserve dead-owner takeover followed by `Recovery.recover/5`, and keep stop requests and status reads available during a live drain.

## Request
Running `kogen queue start` while another `kogen queue start` for the same project is already draining makes the second one claim the same approved Intent and fail it with build_already_claimed, so the Intent ends failed although the first runner is still building it. A second `kogen queue start` for a project whose queue is already running must not touch any Intent: it prints that the queue is already running (with the runner's pid and start time) and exits 0. A runner that died without releasing (pid no longer alive) must not block a new start; the new start takes over and recovers the interrupted Build automatically as today. `kogen queue stop` and `kogen status` keep working while a runner is active.
