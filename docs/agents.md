Every Harness role invocation (context, planner, builder, reviewer, shaper, auditor and
edge writer) creates a random agent identity under its run's `agents/<id>/` directory.
Nested invocations keep `parent_id`; parallel invocations have separate identities.
The record includes the project, owning Build, role, current turn, elapsed time and
running/waiting/finished state. Provider waits are identified as waiting.

`kogen status` shows agent records for the selected project alongside queue and Intent
status. `kogen status <slug>` shows records belonging to that Intent's latest Build.
The existing `--project`, `--origin` and `--base` options keep their meanings.

With `--json`, the project view emits its existing Intent objects followed by agent
objects identified by `"type": "agent"`. The single-Intent Build report includes an
`agents` array when records exist. With `--watch`, agent activity and completion are
printed as they change; watching continues while any project agent is running or waiting.
Projects without agent records retain their existing output.

The output includes `events_path` for retained activity events. Completed records retain
their outcome and elapsed time. Owners renew their record every 50 ms; an interrupted
owner leaves a stale record after five seconds. Stale records do not keep watch running.

Use `kogen queue stop` to ask the queue to finish its current Build and then stop.
This keeps existing queue approval, stop and landing behavior. Agent records provide
observation without a resident daemon or separate agent control commands.
